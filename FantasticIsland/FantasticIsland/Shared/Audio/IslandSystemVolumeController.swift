import AppKit
import ApplicationServices
import Combine
import CoreAudio
import Foundation
import SwiftUI

enum IslandSystemVolumeOverlayPhase: Equatable {
    case hidden
    case expanded
}

final class IslandSystemVolumeController: NSObject, ObservableObject {
    static let shared = IslandSystemVolumeController()
    static let didChangeNotification = Notification.Name("FantasticIsland.systemVolumeDidChange")

    static let closedOverlayWidth: CGFloat = 112
    // Keeps the progress bar visually inside the shell's trailing edge while
    // leaving a small amount of breathing room after the bar.
    static let closedOverlayTrailingInset: CGFloat = 10
    // Matches boring.notch's sneak-peek duration.
    static let overlayVisibleDuration: TimeInterval = 1.5

    @Published private(set) var volume: CGFloat = 0
    @Published private(set) var isMuted = false
    @Published private(set) var lastChangeAt = Date.distantPast
    @Published private(set) var overlayPhase: IslandSystemVolumeOverlayPhase = .hidden
    @Published private(set) var overlayExpansionProgress: CGFloat = 0

    private enum KeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case mute = 7
    }

    private let step: Float32 = 1.0 / 16.0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var observedDeviceID: AudioObjectID = kAudioObjectUnknown
    private var currentDeviceListenerBlocks: [
        (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)
    ] = []
    private var didInitialFetch = false
    private var previousVolumeBeforeMute: Float32 = 0.2
    private var softwareMuted = false
    private var accessibilityRetryScheduled = false
    private var hasPresentedAccessibilityPrompt = false
    private var overlayHideWorkItem: DispatchWorkItem?

    private override init() {
        super.init()
        refresh()
        setupAudioListeners()
    }

    deinit {
        overlayHideWorkItem?.cancel()
        stop()
        removeAudioListeners()
    }

    var shouldShowOverlay: Bool {
        overlayPhase == .expanded
    }

    var shouldExpandOverlay: Bool {
        overlayPhase == .expanded
    }

    var shouldShowOverlayContent: Bool {
        overlayPhase == .expanded
    }

    func start() {
        guard eventTap == nil else { return }

        guard AXIsProcessTrusted() else {
            if !hasPresentedAccessibilityPrompt {
                hasPresentedAccessibilityPrompt = true
                _ = AXIsProcessTrustedWithOptions([
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
                ] as CFDictionary)
            }
            scheduleAccessibilityRetry()
            return
        }

        let systemDefinedType = CGEventType(rawValue: 14)!
        let mask = CGEventMask(1 << systemDefinedType.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passRetained(event)
                }

                let controller = Unmanaged<IslandSystemVolumeController>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                return controller.handle(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func scheduleAccessibilityRetry() {
        guard !accessibilityRetryScheduled else { return }
        accessibilityRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.accessibilityRetryScheduled = false
            self.start()
        }
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    func increase() {
        setAbsolute((readVolume() ?? Float32(volume)) + step)
    }

    func decrease() {
        setAbsolute((readVolume() ?? Float32(volume)) - step)
    }

    func toggleMute() {
        let deviceID = defaultOutputDeviceID()
        let currentlyMuted = deviceID == kAudioObjectUnknown ? softwareMuted : readMute(deviceID: deviceID)
        let nextMuted = !currentlyMuted

        if nextMuted {
            let current = readVolume() ?? Float32(volume)
            if current > 0.001 { previousVolumeBeforeMute = current }
        }

        if deviceID != kAudioObjectUnknown, setMute(deviceID: deviceID, muted: nextMuted) {
            publish(volume: nextMuted ? 0 : (readVolume() ?? previousVolumeBeforeMute), muted: nextMuted)
        } else {
            softwareMuted = nextMuted
            _ = writeVolume(nextMuted ? 0 : previousVolumeBeforeMute)
            publish(volume: nextMuted ? 0 : previousVolumeBeforeMute, muted: nextMuted)
        }
    }

    func setAbsolute(_ value: CGFloat) {
        setAbsolute(Float32(value))
    }

    func setAbsolute(_ value: Float32) {
        let clamped = max(0, min(1, value))
        let wasMuted = isMutedInternal()
        if wasMuted && clamped > 0 { toggleMuteInternal() }
        _ = writeVolume(clamped)
        if clamped == 0 && !wasMuted { toggleMuteInternal() }
        publish(volume: clamped, muted: isMutedInternal())
    }

    func refresh() {
        let currentVolume = readVolume() ?? Float32(volume)
        publish(volume: currentVolume, muted: isMutedInternal(), showOverlay: false)
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passRetained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let stateByte = (data1 & 0xFF00) >> 8
        guard stateByte == 0xA,
              let keyType = KeyType(rawValue: keyCode) else {
            return Unmanaged.passRetained(event)
        }

        DispatchQueue.main.async { [weak self] in
            switch keyType {
            case .soundUp:
                self?.increase()
            case .soundDown:
                self?.decrease()
            case .mute:
                self?.toggleMute()
            }
        }

        // Returning nil prevents the stock macOS volume bezel from appearing.
        return nil
    }

    private func setupAudioListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(systemObject, &defaultDeviceAddress, DispatchQueue.main) { [weak self] _, _ in
            self?.refresh()
            self?.setupCurrentDeviceListeners()
        }
        setupCurrentDeviceListeners()
    }

    private func setupCurrentDeviceListeners() {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown, deviceID != observedDeviceID else {
            refresh()
            return
        }

        removeCurrentDeviceListeners()
        observedDeviceID = deviceID
        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute,
        ]
        for selector in selectors {
            for element in supportedPropertyElements(deviceID: deviceID, selector: selector) {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.refresh()
                }
                guard AudioObjectAddPropertyListenerBlock(
                    deviceID,
                    &address,
                    DispatchQueue.main,
                    listener
                ) == noErr else {
                    continue
                }
                currentDeviceListenerBlocks.append((address: address, block: listener))
            }
        }
        refresh()
    }

    private func removeAudioListeners() {
        removeCurrentDeviceListeners()
    }

    private func removeCurrentDeviceListeners() {
        guard observedDeviceID != kAudioObjectUnknown else { return }
        for entry in currentDeviceListenerBlocks {
            var address = entry.address
            AudioObjectRemovePropertyListenerBlock(
                observedDeviceID,
                &address,
                DispatchQueue.main,
                entry.block
            )
        }
        currentDeviceListenerBlocks.removeAll(keepingCapacity: true)
        observedDeviceID = kAudioObjectUnknown
    }

    /// Bluetooth output devices commonly expose volume only on their channel
    /// elements (usually 1 and 2), while built-in output also exposes the
    /// main element. Always use the elements the device actually advertises.
    private func supportedPropertyElements(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> [UInt32] {
        [
            kAudioObjectPropertyElementMain,
            1,
            2,
            3,
            4,
        ].filter { element in
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            return AudioObjectHasProperty(deviceID, &address)
        }
    }

    private func supportedVolumeElements(deviceID: AudioObjectID) -> [UInt32] {
        supportedPropertyElements(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar)
    }

    private func supportedMuteElements(deviceID: AudioObjectID) -> [UInt32] {
        supportedPropertyElements(deviceID: deviceID, selector: kAudioDevicePropertyMute)
    }

    private func defaultOutputDeviceID() -> AudioObjectID {
        var deviceID = kAudioObjectUnknown
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else {
            return kAudioObjectUnknown
        }
        return deviceID
    }

    private func readVolume() -> Float32? {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return nil }

        let elements = supportedVolumeElements(deviceID: deviceID)
        guard !elements.isEmpty else { return nil }

        // Prefer the device master value when it exists. For Bluetooth
        // devices this is usually absent, so fall back to the channel mean.
        if elements.contains(kAudioObjectPropertyElementMain),
           let master = readScalar(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return max(0, min(1, master))
        }

        let values = elements.compactMap { readScalar(deviceID: deviceID, element: $0) }
        guard !values.isEmpty else { return nil }
        return max(0, min(1, values.reduce(0, +) / Float32(values.count)))
    }

    private func readScalar(deviceID: AudioObjectID, element: UInt32) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr else {
            return nil
        }
        return volume
    }

    private func writeVolume(_ value: Float32) -> Bool {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return false }

        let elements = supportedVolumeElements(deviceID: deviceID)
        guard !elements.isEmpty else { return false }

        var didWrite = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var volume = value
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume) == noErr {
                didWrite = true
            }
        }
        return didWrite
    }

    private func readMute(deviceID: AudioObjectID) -> Bool {
        let elements = supportedMuteElements(deviceID: deviceID)
        guard !elements.isEmpty else { return softwareMuted }

        // A device is muted if its master or any exposed output channel says
        // so. This also covers Bluetooth devices without a master element.
        return elements.contains { element in
            readMuteScalar(deviceID: deviceID, element: element) ?? false
        }
    }

    private func readMuteScalar(deviceID: AudioObjectID, element: UInt32) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr else {
            return nil
        }
        return muted != 0
    }

    private func setMute(deviceID: AudioObjectID, muted: Bool) -> Bool {
        let elements = supportedMuteElements(deviceID: deviceID)
        guard !elements.isEmpty else { return false }

        var didWrite = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var value: UInt32 = muted ? 1 : 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr {
                didWrite = true
            }
        }
        return didWrite
    }

    private func isMutedInternal() -> Bool {
        let deviceID = defaultOutputDeviceID()
        return deviceID == kAudioObjectUnknown ? softwareMuted : readMute(deviceID: deviceID)
    }

    private func toggleMuteInternal() {
        let deviceID = defaultOutputDeviceID()
        if deviceID != kAudioObjectUnknown, setMute(deviceID: deviceID, muted: !readMute(deviceID: deviceID)) {
            return
        }
        softwareMuted.toggle()
    }

    private func publish(volume: Float32, muted: Bool, showOverlay: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let clamped = CGFloat(max(0, min(1, volume)))
            self.volume = clamped
            self.isMuted = muted
            if showOverlay {
                let changeDate = Date()
                self.lastChangeAt = changeDate
                self.beginOverlayPresentation(for: changeDate)
            }
            self.didInitialFetch = true
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: nil
            )
        }
    }

    private func beginOverlayPresentation(for changeDate: Date) {
        overlayHideWorkItem?.cancel()

        // Keep the HUD as one SwiftUI state transition, exactly like
        // boring.notch's sneakPeek. The fixed AppKit host does not participate
        // in this animation, so the shell and HUD share one compositing pass.
        withAnimation(.smooth) {
            overlayPhase = .expanded
            overlayExpansionProgress = 1
        }
        postOverlayChange()

        let hide = DispatchWorkItem { [weak self] in
            guard let self,
                  self.lastChangeAt == changeDate else { return }
            withAnimation(.smooth) {
                self.overlayPhase = .hidden
                self.overlayExpansionProgress = 0
            }
            self.postOverlayChange()
        }
        overlayHideWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlayVisibleDuration, execute: hide)
    }

    private func postOverlayChange() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil
        )
    }
}
