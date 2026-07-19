import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class PlayerModuleModel: ObservableObject, IslandModule {
    static let moduleID = "player"
    private static let transientNotificationAutoDismissDelay: TimeInterval = 1.5
    private static let trackSwitchActivityPriority = 240
    private static let estimatedArtworkBlockHeight: CGFloat = 112
    private static let estimatedProgressSectionHeight: CGFloat = 30
    private static let estimatedOuterSpacing: CGFloat = 18

    private struct TrackIdentity: Hashable {
        let source: PlayerSourceKind
        let title: String
        let artist: String
        let album: String

        init?(state: PlayerNowPlayingState) {
            guard let source = state.source,
                  let track = state.track else {
                return nil
            }

            self.init(source: source, track: track)
        }

        init(source: PlayerSourceKind, track: PlayerTrackMetadata) {
            self.source = source
            self.title = track.title
            self.artist = track.artist
            self.album = track.album ?? ""
        }
    }

    struct TrackSwitchNotification {
        let activityID: String
        let source: PlayerSourceKind
        let track: PlayerTrackMetadata
        let artworkImage: NSImage?
        let createdAt: Date
        let updatedAt: Date
    }

    let id = PlayerModuleModel.moduleID
    let title = "Player"
    let symbolName = "play.square.fill"
    let iconAssetName: String? = nil

    @Published private(set) var nowPlayingState: PlayerNowPlayingState = .empty
    // Separate from nowPlayingState, as in boring.notch's MusicManager:
    // transport events update immediately while artwork can decode in the
    // background without delaying or rebuilding playback metadata.
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var installedSourceApps: [PlayerAppDescriptor] = []
    @Published private(set) var defaultSourceOptions: [PlayerSourceKind] = []
    @Published private(set) var defaultSource: PlayerSourceKind?
    @Published private(set) var trackSwitchPopupEnabled = true
    @Published private(set) var trackSwitchNotification: TrackSwitchNotification?
    @Published private(set) var isResolvingAutomationAccess = false

    private let mediaCoordinator = PlayerMediaCoordinator()
    private var mediaUpdatesTask: Task<Void, Never>?
    private var artworkLoadTask: Task<Void, Never>?
    private var artworkLoadIdentity: TrackIdentity?
    // A title event can arrive before MediaRemote's artwork diff. Keep the
    // exact raw bytes as the de-duplication key, as Boring Notch does, so a
    // later cover update is never confused with a metadata-only event.
    private var artworkLoadData: Data?
    // Like boring.notch's separate `artworkData` and `albumArt` properties,
    // this records which raw artwork bytes the currently displayed image came
    // from. A new Data value must start a decode even while the old image is
    // still being displayed.
    private var artworkImageData: Data?
    private var artworkPrefetchTask: Task<Void, Never>?
    private var artworkPrefetchIdentity: TrackIdentity?
    // The track-switch activity and the standard Player view can be rendered
    // by different live hosts. Keep the most recent decoded artwork available
    // to both hosts, just like the persistent artwork state in boring.notch.
    private var recentArtworkCache: [TrackIdentity: NSImage] = [:]
    private var recentArtworkCacheOrder: [TrackIdentity] = []
    private var pendingRefreshWorkItem: DispatchWorkItem?
    private var lastObservedTrackIdentity: TrackIdentity?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private static let automationSettingsURLs: [URL] = [
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"),
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
    ].compactMap { $0 }
    private static let playbackNotificationNames: [Notification.Name] = [
        Notification.Name("com.apple.Music.playerInfo"),
        Notification.Name("com.apple.iTunes.playerInfo"),
        Notification.Name("com.apple.podcasts.playerInfo"),
        Notification.Name("com.apple.Podcasts.playerInfo"),
        Notification.Name("com.spotify.client.PlaybackStateChanged"),
    ]

    init() {
        let defaults = IslandDefaults.defaults
        trackSwitchPopupEnabled = defaults.object(
            forKey: IslandDefaults.playerTrackSwitchPopupEnabledKey
        ) == nil || defaults.bool(forKey: IslandDefaults.playerTrackSwitchPopupEnabledKey)
        syncSourceAvailability()
        configureWorkspaceObservers()
        configureDistributedPlaybackObservers()
        mediaUpdatesTask = Task { [weak self] in
            await self?.observeSystemNowPlayingUpdates()
        }
    }

    deinit {
        mediaUpdatesTask?.cancel()
        artworkLoadTask?.cancel()
        artworkPrefetchTask?.cancel()
        pendingRefreshWorkItem?.cancel()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    var collapsedSummaryItems: [CollapsedSummaryItem] {
        [
            CollapsedSummaryItem(
                id: "\(id).summary.playback",
                moduleID: id,
                title: "Playback",
                text: nowPlayingState.collapsedSummaryText,
                isEnabledByDefault: false
            ),
        ]
    }

    var taskActivityContribution: TaskActivityContribution {
        TaskActivityContribution()
    }

    var islandActivities: [IslandActivity] {
        guard let trackSwitchNotification else {
            return []
        }

        return [
            IslandActivity(
                id: trackSwitchNotification.activityID,
                moduleID: id,
                sourceID: trackSwitchNotification.activityID,
                kind: .transientNotification,
                priority: Self.trackSwitchActivityPriority,
                createdAt: trackSwitchNotification.createdAt,
                updatedAt: trackSwitchNotification.updatedAt,
                presentationPolicy: IslandActivityPresentationPolicy(
                    autoPresentationScope: .global,
                    autoDismissDelay: Self.transientNotificationAutoDismissDelay,
                    switchSelectedModuleOnAutoPresentation: false,
                    promoteWhileExpanded: false
                )
            ),
        ]
    }

    var preferredOpenedContentHeight: CGFloat {
        let estimatedBodyHeight =
            Self.estimatedArtworkBlockHeight
            + Self.estimatedOuterSpacing
            + Self.estimatedProgressSectionHeight
        let alignedBodyHeight =
            CodexIslandChromeMetrics.windDrivePanelHeight
            - CodexIslandChromeMetrics.moduleNavigationRowHeight
            - CodexIslandChromeMetrics.moduleColumnSpacing

        return CodexIslandChromeMetrics.moduleChromeHeight + max(estimatedBodyHeight, alignedBodyHeight)
    }
    var allowsInternalScrolling: Bool { false }

    var supportsTransportControls: Bool {
        guard nowPlayingState.automationIssue == nil else {
            return false
        }

        return nowPlayingState.supportsTransportControls || defaultSource != nil
    }

    var automationIssue: PlayerAutomationIssue? {
        nowPlayingState.automationIssue
    }

    var canRequestAutomationAccess: Bool {
        automationIssue != nil && !isResolvingAutomationAccess
    }

    var defaultSourceSelection: PlayerSourceKind {
        defaultSource ?? defaultSourceOptions.first ?? .music
    }

    var installedSourceDisplayText: String {
        joinedSourceNames(from: installedSourceApps.map(\.displayName))
    }

    var controllableSourceDisplayText: String {
        joinedSourceNames(from: defaultSourceOptions.map(\.displayName))
    }

    func preferredOpenedContentHeight(for presentation: IslandModulePresentationContext) -> CGFloat {
        switch presentation {
        case .peek:
            return CodexIslandPeekMetrics.contentTopPadding
                + PlayerPeekMetrics.minimumHeight
                + CodexIslandPeekMetrics.contentBottomPadding
        case .standard, .activity:
            return preferredOpenedContentHeight
        }
    }

    func makeRenderSnapshot(presentation: IslandModulePresentationContext) -> IslandModuleRenderSnapshot {
        IslandModuleRenderSnapshot(
            id: "\(id)::\(presentation.cacheKey)",
            moduleID: id,
            presentation: presentation,
            preferredHeight: preferredOpenedContentHeight(for: presentation),
            allowsInternalScrolling: allowsInternalScrolling,
            view: AnyView(PlayerModuleContentView(state: makeRenderState(for: presentation)))
        )
    }

    func makeLiveContentView(presentation: IslandModulePresentationContext) -> AnyView {
        AnyView(PlayerModuleLiveContentView(model: self, presentation: presentation))
    }

    func makeRenderState(for presentation: IslandModulePresentationContext) -> PlayerModuleRenderState {
        let resolvedNotification: TrackSwitchNotification?
        switch presentation {
        case let .peek(activity):
            resolvedNotification = trackSwitchNotification(for: activity)
        case .standard, .activity:
            resolvedNotification = nil
        }

        let resolvedNowPlayingState = nowPlayingState
        let resolvedArtworkImage = artworkImage
            ?? TrackIdentity(state: resolvedNowPlayingState).flatMap { recentArtworkCache[$0] }

        let sourceIconImages = Dictionary(
            uniqueKeysWithValues: defaultSourceOptions.compactMap { sourceKind -> (PlayerSourceKind, NSImage)? in
                guard let image = PlayerSourceRegistry.appIcon(for: sourceKind) else {
                    return nil
                }

                return (sourceKind, image)
            }
        )

        let selectedPlaybackSource = resolvedNowPlayingState.source ?? defaultSourceSelection
        var resolvedSourceOptions = defaultSourceOptions
        if let activeSource = resolvedNowPlayingState.source,
           !resolvedSourceOptions.contains(activeSource) {
            resolvedSourceOptions.append(activeSource)
        }

        var resolvedSourceIconImages = sourceIconImages
        if let bundleIdentifier = resolvedNowPlayingState.applicationBundleIdentifier,
           !bundleIdentifier.isEmpty,
           let applicationURL = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: bundleIdentifier
        ) {
            let applicationIcon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            applicationIcon.size = NSSize(width: 64, height: 64)
            resolvedSourceIconImages[selectedPlaybackSource] = applicationIcon
        }

        return PlayerModuleRenderState(
            presentation: presentation,
            nowPlayingState: resolvedNowPlayingState,
            artworkImage: resolvedArtworkImage,
            trackSwitchNotification: resolvedNotification,
            supportsTransportControls: supportsTransportControls,
            automationIssue: automationIssue,
            canRequestAutomationAccess: canRequestAutomationAccess,
            isResolvingAutomationAccess: isResolvingAutomationAccess,
            sourceOptions: resolvedSourceOptions,
            selectedSource: selectedPlaybackSource,
            sourceIconImages: resolvedSourceIconImages,
            activeApplicationName: nowPlayingState.applicationDisplayName,
            // SwiftUI invokes these actions on the model's main actor. Keep
            // the closures synchronous so a MediaRemote click is dispatched
            // immediately instead of waiting for an extra unstructured Task
            // hop before the coordinator can send the command.
            previousTrack: { [weak self] in self?.previousTrack() },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            nextTrack: { [weak self] in self?.nextTrack() },
            seek: { [weak self] progress in self?.seek(toProgress: progress) },
            toggleShuffle: { [weak self] in self?.toggleShuffle() },
            cycleRepeat: { [weak self] in self?.cycleRepeat() },
            requestAutomationAccess: { [weak self] in self?.requestAutomationAccess() },
            openAutomationSettings: { [weak self] in self?.openAutomationSettings() },
            refresh: { [weak self] in self?.refresh() },
            selectSource: { [weak self] source in self?.selectPlaybackSource(source) }
        )
    }

    func refresh() {
        pendingRefreshWorkItem?.cancel()
        pendingRefreshWorkItem = nil
        syncSourceAvailability()

        // The persistent MediaRemote subscriber owns visual state. A manual
        // refresh only ensures the stream has started; it must not re-select
        // a stale Music/Chrome snapshot over a newer pushed update.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let nextState = await self.mediaCoordinator.fetchCurrentState(
                preferredSourceKind: self.defaultSource
            )
            self.applyNowPlayingState(nextState)
        }
    }

    func previousTrack() {
        if let refreshDelay = mediaCoordinator.previousTrack(for: nowPlayingState.source) {
            refreshSoon(after: refreshDelay)
        }
    }

    func togglePlayPause() {
        guard nowPlayingState.track != nil,
              nowPlayingState.source != nil else {
            return
        }

        // Do not locally invert the state: MediaRemote's `playing` value is
        // authoritative and a local optimistic flip can briefly show the
        // opposite icon when the command targets a browser session.
        // Refresh repeatedly because the stream publishes the transport
        // result asynchronously.
        if let refreshDelay = mediaCoordinator.togglePlayPause(for: nowPlayingState.source) {
            refreshSoon(after: min(refreshDelay, 0.08))
            for delay in [0.42, 0.9] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    func nextTrack() {
        if let refreshDelay = mediaCoordinator.nextTrack(for: nowPlayingState.source) {
            refreshSoon(after: refreshDelay)
        }
    }

    func seek(toProgress progress: Double) {
        guard let track = nowPlayingState.track, track.duration > 0 else {
            return
        }

        let clampedProgress = min(max(progress, 0), 1)
        let targetElapsed = track.duration * clampedProgress
        mediaCoordinator.seek(to: targetElapsed, for: nowPlayingState.source)
        var updatedState = nowPlayingState
        updatedState.track?.elapsed = targetElapsed
        nowPlayingState = updatedState
        refreshSoon()
    }

    func activateCurrentSource() {
        guard canActivateCurrentSource else {
            return
        }

        mediaCoordinator.activateSourceApplication(for: nowPlayingState.source)
    }

    func toggleShuffle() {
        mediaCoordinator.toggleShuffle(for: nowPlayingState.source)
        refreshSoon()
    }

    func cycleRepeat() {
        mediaCoordinator.cycleRepeat(for: nowPlayingState.source)
        refreshSoon()
    }

    func setDefaultSource(_ sourceKind: PlayerSourceKind) {
        defaultSource = PlayerModuleSettings.setDefaultSource(
            sourceKind,
            installedControllableSources: defaultSourceOptions
        )
    }

    func selectPlaybackSource(_ sourceKind: PlayerSourceKind) {
        // The generic system source is selected automatically from the active
        // MediaRemote session and must not replace the user's default app.
        if sourceKind == .system {
            refreshSoon(after: 0.05)
            return
        }

        let resolvedSource = PlayerModuleSettings.setDefaultSource(
            sourceKind,
            installedControllableSources: defaultSourceOptions
        )
        defaultSource = resolvedSource

        guard resolvedSource == sourceKind else {
            return
        }

        mediaCoordinator.activateSourceApplication(for: sourceKind)
        if nowPlayingState.source != sourceKind {
            nowPlayingState = .idleState(source: sourceKind)
        }
        refreshSoon(after: 0.35)
    }

    func requestAutomationAccess() {
        guard let sourceKind = nowPlayingState.automationIssueSource ?? defaultSource else {
            return
        }

        requestAutomationAccess(for: sourceKind)
    }

    func openAutomationSettings() {
        for url in Self.automationSettingsURLs where NSWorkspace.shared.open(url) {
            return
        }

        let settingsBundleIDs = [
            "com.apple.SystemSettings",
            "com.apple.systempreferences",
        ]
        for bundleIdentifier in settingsBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private func refreshSoon(after delay: TimeInterval = 0.25) {
        pendingRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.pendingRefreshWorkItem = nil
            self.refresh()
        }

        pendingRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem
        )
    }

    private func observeSystemNowPlayingUpdates() async {
        let updates = await mediaCoordinator.systemNowPlayingUpdates()
        for await nextState in updates {
            guard !Task.isCancelled else {
                return
            }
            syncSourceAvailability()
            applyNowPlayingState(nextState)
        }
    }

    private func applyNowPlayingState(_ nextState: PlayerNowPlayingState) {
        // Keep albumArt independent from the transport snapshot, like
        // boring.notch's MusicManager. MediaRemote emits many progress and
        // play/pause diffs without repeating artworkData; those diffs must not
        // clear an already decoded cover. A new artworkData value starts a
        // replacement decode while the previous complete cover remains
        // visible.
        let previousIdentity = TrackIdentity(state: nowPlayingState)
        let nextIdentity = TrackIdentity(state: nextState)
        if previousIdentity != nextIdentity {
            // A new source/track owns a new artwork slot. Cancelling the old
            // decode here prevents a late Apple Music image being assigned to
            // Chrome (or the reverse). The replacement image is still decoded
            // entirely independently from the playback metadata below.
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadIdentity = nil
            artworkLoadData = nil
            artworkImage = nextState.artworkImage
            artworkImageData = nil
        }

        processTrackSwitch(from: nowPlayingState, to: nextState)
        if nextState != nowPlayingState {
            nowPlayingState = nextState
        }
        requestArtworkLoadIfNeeded(for: nowPlayingState)
    }

    private func rememberArtwork(from state: PlayerNowPlayingState) {
        guard let artworkImage,
              let identity = TrackIdentity(state: state) else {
            return
        }

        recentArtworkCache[identity] = artworkImage
        recentArtworkCacheOrder.removeAll { $0 == identity }
        recentArtworkCacheOrder.append(identity)

        while recentArtworkCacheOrder.count > 8,
              let oldestIdentity = recentArtworkCacheOrder.first {
            recentArtworkCacheOrder.removeFirst()
            recentArtworkCache.removeValue(forKey: oldestIdentity)
        }
    }

    private func updateTrackSwitchArtworkIfNeeded(
        with artworkImage: NSImage,
        for state: PlayerNowPlayingState
    ) {
        guard let notification = trackSwitchNotification,
              let identity = TrackIdentity(state: state),
              TrackIdentity(source: notification.source, track: notification.track) == identity,
              notification.artworkImage == nil else {
            return
        }

        // The popup may be created before MediaRemote's artwork diff arrives.
        // Replace only that same track's missing image; never attach a late
        // image from an older source to a newer notification.
        trackSwitchNotification = TrackSwitchNotification(
            activityID: notification.activityID,
            source: notification.source,
            track: notification.track,
            artworkImage: artworkImage,
            createdAt: notification.createdAt,
            updatedAt: Date()
        )
    }

    private func configureWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let observedNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]

        for name in observedNames {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let bundleIdentifier =
                    (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier

                Task { @MainActor [weak self, bundleIdentifier] in
                    guard let self,
                          let bundleIdentifier,
                          PlayerSourceKind.allCases.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                        return
                    }

                    self.refreshSoon(after: 0.1)
                }
            }
            workspaceObservers.append(observer)
        }
    }

    private func configureDistributedPlaybackObservers() {
        let notificationCenter = DistributedNotificationCenter.default()

        for name in Self.playbackNotificationNames {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshSoon(after: 0.05)
                }
            }
            distributedObservers.append(observer)
        }
    }

    var canActivateCurrentSource: Bool {
        nowPlayingState.playbackStatus.isPlaying && nowPlayingState.source != nil
    }

    func trackSwitchNotification(for activity: IslandActivity) -> TrackSwitchNotification? {
        guard trackSwitchNotification?.activityID == activity.id else {
            return Self.debugTrackSwitchNotification(for: activity)
        }

        return trackSwitchNotification
    }

    func setTrackSwitchPopupEnabled(_ enabled: Bool) {
        guard trackSwitchPopupEnabled != enabled else {
            return
        }

        trackSwitchPopupEnabled = enabled
        IslandDefaults.defaults.set(enabled, forKey: IslandDefaults.playerTrackSwitchPopupEnabledKey)
        IslandDefaults.defaults.synchronize()

        if !enabled {
            trackSwitchNotification = nil
        }
    }

    private func syncSourceAvailability() {
        let installedSourceApps = PlayerSourceRegistry.installedDescriptors()
        if installedSourceApps != self.installedSourceApps {
            self.installedSourceApps = installedSourceApps
        }

        let defaultSourceOptions = PlayerSourceRegistry.installedApplePlaybackSources()
        if defaultSourceOptions != self.defaultSourceOptions {
            self.defaultSourceOptions = defaultSourceOptions
        }

        let resolvedDefaultSource = PlayerModuleSettings.reconcileDefaultSource(
            installedControllableSources: defaultSourceOptions
        )
        if resolvedDefaultSource != defaultSource {
            defaultSource = resolvedDefaultSource
        }
    }

    private static func debugTrackSwitchNotification(for activity: IslandActivity) -> TrackSwitchNotification? {
        guard activity.sourceID == "debug.player.trackswitch" else {
            return nil
        }

        let now = Date()
        return TrackSwitchNotification(
            activityID: activity.id,
            source: .music,
            track: PlayerTrackMetadata(
                title: "Debugging Fantastic Island",
                artist: "Fantastic Island",
                album: "UI Runtime Tools",
                duration: 326,
                elapsed: 92,
                artworkURL: nil
            ),
            artworkImage: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private func joinedSourceNames(from names: [String]) -> String {
        names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    private func processTrackSwitch(from previousState: PlayerNowPlayingState, to nextState: PlayerNowPlayingState) {
        let previousIdentity = lastObservedTrackIdentity ?? TrackIdentity(state: previousState)
        guard let nextIdentity = TrackIdentity(state: nextState),
              let source = nextState.source,
              let track = nextState.track else {
            return
        }

        defer {
            lastObservedTrackIdentity = nextIdentity
        }

        guard trackSwitchPopupEnabled else {
            trackSwitchNotification = nil
            return
        }

        guard let previousIdentity,
              previousIdentity != nextIdentity else {
            return
        }

        let timestamp = Date()
        let milliseconds = Int(timestamp.timeIntervalSince1970 * 1000)
        trackSwitchNotification = TrackSwitchNotification(
            activityID: "\(id).activity.track-switch.\(milliseconds)",
            source: source,
            track: track,
            artworkImage: nextState.artworkImage,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func requestAutomationAccess(for sourceKind: PlayerSourceKind) {
        guard !isResolvingAutomationAccess else {
            return
        }

        isResolvingAutomationAccess = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task.detached(priority: .userInitiated) { [sourceKind] in
            _ = PlayerMediaCoordinator.determineAutomationPermission(
                for: sourceKind,
                askUserIfNeeded: true
            )

            await MainActor.run { [weak self] in
                guard let self else {
                    return
                }

                self.isResolvingAutomationAccess = false
                self.refreshSoon(after: 0.1)
            }
        }
    }

    private func requestArtworkLoadIfNeeded(for state: PlayerNowPlayingState) {
        guard let identity = TrackIdentity(state: state) else {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadIdentity = nil
            artworkLoadData = nil
            artworkImageData = nil
            artworkPrefetchTask?.cancel()
            artworkPrefetchTask = nil
            artworkPrefetchIdentity = nil
            return
        }

        scheduleArtworkPrefetchIfNeeded(for: state, identity: identity)

        let artworkData = state.artworkData

        // No artwork Data means that this is a transport-only diff. Keep the
        // current image exactly as boring.notch keeps albumArt on a diff with
        // no artwork field.
        guard let artworkData else {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadIdentity = nil
            artworkLoadData = nil
            return
        }

        // An already visible image is not sufficient to skip the load: the
        // raw artwork Data may have changed for the same track. Only skip when
        // the visible image was decoded from this exact Data value.
        guard artworkImageData != artworkData else {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadIdentity = nil
            artworkLoadData = nil
            return
        }

        guard artworkLoadIdentity != identity || artworkLoadData != artworkData else {
            return
        }

        artworkLoadTask?.cancel()
        artworkLoadIdentity = identity
        artworkLoadData = artworkData

        artworkLoadTask = Task { [weak self, state, identity, artworkData] in
            guard let self else {
                return
            }

            defer {
                if self.artworkLoadIdentity == identity,
                   self.artworkLoadData == artworkData {
                    self.artworkLoadTask = nil
                    self.artworkLoadIdentity = nil
                    self.artworkLoadData = nil
                }
            }

            guard let artworkImage = await self.mediaCoordinator.loadArtworkIfNeeded(for: state),
                  !Task.isCancelled,
                  self.artworkLoadIdentity == identity,
                  self.artworkLoadData == artworkData,
                  TrackIdentity(state: self.nowPlayingState) == identity else {
                return
            }

            // Assign the complete value instead of mutating a nested field in
            // place. This guarantees @Published emits an update immediately
            // when artwork arrives after the title/artist snapshot.
            var updatedState = self.nowPlayingState
            updatedState.artworkImage = artworkImage
            self.artworkImage = artworkImage
            self.artworkImageData = artworkData
            self.rememberArtwork(from: updatedState)
            self.updateTrackSwitchArtworkIfNeeded(with: artworkImage, for: updatedState)
            // Do not write artwork back into nowPlayingState. boring.notch's
            // MusicManager updates albumArt independently from PlaybackState;
            // publishing a transport snapshot here can race a newer Chrome /
            // Apple Music event and make source switching appear delayed.
        }
    }

    private func scheduleArtworkPrefetchIfNeeded(
        for state: PlayerNowPlayingState,
        identity: TrackIdentity
    ) {
        guard state.source == .music,
              state.shuffleMode == .off else {
            artworkPrefetchTask?.cancel()
            artworkPrefetchTask = nil
            artworkPrefetchIdentity = nil
            return
        }

        guard artworkPrefetchIdentity != identity else {
            return
        }

        artworkPrefetchTask?.cancel()
        artworkPrefetchIdentity = identity

        artworkPrefetchTask = Task { [weak self, state, identity] in
            guard let self else {
                return
            }

            defer {
                if self.artworkPrefetchIdentity == identity {
                    self.artworkPrefetchTask = nil
                }
            }

            await self.mediaCoordinator.prefetchUpcomingArtwork(after: state, limit: 2)
        }
    }

}
