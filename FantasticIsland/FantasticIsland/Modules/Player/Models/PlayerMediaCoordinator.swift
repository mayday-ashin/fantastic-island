import AppKit
import Carbon
import Foundation
import ImageIO

private nonisolated func playerImageIOArtworkImage(from data: Data) -> NSImage? {
    let sourceOptions = [
        kCGImageSourceShouldCache: false,
    ] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
        return nil
    }

    // Decode the original representation first. Some Apple Music payloads
    // contain a large/progressive representation for which asking ImageIO
    // for a thumbnail first can return a bitmap whose lower portion has not
    // been fully materialized. This keeps boring.notch's raw-Data pipeline,
    // but guarantees that the cover is a complete image before it reaches
    // SwiftUI. Thumbnail decoding remains a bounded fallback for formats
    // that do not expose a directly decodable image at index 0.
    let imageOptions = [
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceShouldCache: true,
    ] as CFDictionary
    let thumbnailOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: 1024,
    ] as CFDictionary

    // MediaRemote can expose more than one representation. Selecting the
    // largest representation prevents AppKit/SwiftUI from choosing a small
    // progressive representation whose lower rows are not materialized yet.
    let bestIndex = (0..<CGImageSourceGetCount(source)).max { lhs, rhs in
        let lhsProperties = CGImageSourceCopyPropertiesAtIndex(source, lhs, nil) as? [CFString: Any]
        let rhsProperties = CGImageSourceCopyPropertiesAtIndex(source, rhs, nil) as? [CFString: Any]
        let lhsWidth = (lhsProperties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let lhsHeight = (lhsProperties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let rhsWidth = (rhsProperties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let rhsHeight = (rhsProperties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return lhsWidth * lhsHeight < rhsWidth * rhsHeight
    } ?? 0

    guard let cgImage = CGImageSourceCreateImageAtIndex(source, bestIndex, imageOptions)
        ?? CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
        return nil
    }

    return NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
    )
}

private nonisolated func playerDecodedArtworkImage(from data: Data) -> NSImage? {
    // Match boring.notch's MusicManager exactly: keep the raw artwork bytes
    // as the source of truth and let AppKit decode the complete NSImage on a
    // background queue. AppKit preserves Apple Music's multi-representation
    // image better than eagerly selecting one ImageIO representation.
    // Materialize raster artwork through ImageIO first. NSImage(data:) may
    // retain a lazy/progressive representation; passing that representation
    // directly to SwiftUI is the source of the intermittent half-rendered
    // covers. AppKit remains the fallback for formats ImageIO cannot expose.
    if let image = playerImageIOArtworkImage(from: data) {
        return image
    }

    return NSImage(data: data)
}

private nonisolated func playerArtworkData(from encodedValue: String) -> Data? {
    let value = encodedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let base64Value: String
    if let separator = value.firstIndex(of: ","),
       value[..<separator].localizedCaseInsensitiveContains("base64") {
        base64Value = String(value[value.index(after: separator)...])
    } else {
        base64Value = value
    }

    // Browser Media Sessions may wrap artwork in a data URL or insert line
    // breaks into the Base64 payload. Normalize it before decoding so the
    // same artwork data accepted by boring.notch is not silently discarded.
    let normalized = base64Value.filter { !$0.isWhitespace && !$0.isNewline }
    // boring.notch uses strict Base64 decoding. Silently ignoring invalid
    // characters can turn a damaged payload into a seemingly valid but
    // truncated image, which AppKit may render as an incomplete cover.
    return Data(base64Encoded: normalized)
}

private actor PlayerAppleScriptWorker {
    func execute(_ lines: [String]) -> PlayerMediaCoordinator.AppleScriptExecutionResult {
        PlayerMediaCoordinator.runAppleScript(lines)
    }
}

private nonisolated final class PlayerMediaRemoteBridge: @unchecked Sendable {
    static let shared = PlayerMediaRemoteBridge()

    enum Command: Int, Sendable {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    struct Snapshot {
        let applicationBundleIdentifier: String?
        let applicationDisplayName: String?
        let playbackStatus: PlayerPlaybackStatus
        let track: PlayerTrackMetadata?
        let artworkData: Data?
        let artworkImage: NSImage?
        let shuffleMode: PlayerShuffleMode
        let repeatMode: PlayerRepeatMode
        let timestampDate: Date
        let playbackRate: Double

        init(
            applicationBundleIdentifier: String?,
            applicationDisplayName: String?,
            playbackStatus: PlayerPlaybackStatus,
            track: PlayerTrackMetadata?,
            artworkData: Data? = nil,
            artworkImage: NSImage?,
            shuffleMode: PlayerShuffleMode = .unsupported,
            repeatMode: PlayerRepeatMode = .unsupported,
            timestampDate: Date = .distantPast,
            playbackRate: Double = 1
        ) {
            self.applicationBundleIdentifier = applicationBundleIdentifier
            self.applicationDisplayName = applicationDisplayName
            self.playbackStatus = playbackStatus
            self.track = track
            self.artworkData = artworkData
            self.artworkImage = artworkImage
            self.shuffleMode = shuffleMode
            self.repeatMode = repeatMode
            self.timestampDate = timestampDate
            self.playbackRate = playbackRate
        }
    }

    private struct HelperPayload: Decodable {
        let displayID: String?
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsed: Double?
        let playbackRate: Double?
        let isPlaying: Bool?
        let artworkURL: String?
        let artworkDataBase64: String?
        let timestamp: String?
    }

    private typealias GetStringCallback = @convention(block) (String?) -> Void
    private typealias GetBoolCallback = @convention(block) (Bool) -> Void
    private typealias GetInfoCallback = @convention(block) ([AnyHashable: Any]?) -> Void
    private typealias GetStringFunction = @convention(c) (DispatchQueue, @escaping GetStringCallback) -> Void
    private typealias GetBoolFunction = @convention(c) (DispatchQueue, @escaping GetBoolCallback) -> Void
    private typealias GetInfoFunction = @convention(c) (DispatchQueue, @escaping GetInfoCallback) -> Void
    // Matches boring.notch's MediaRemote bridge signature. The second
    // argument is an Objective-C object, not a CFDictionary specifically.
    private typealias SendCommandFunction = @convention(c) (Int, AnyObject?) -> Void
    private typealias SetElapsedTimeFunction = @convention(c) (Double) -> Void

    private final class ContinuationBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        func resume(returning value: Value) {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()

            continuation.resume(returning: value)
        }
    }

    // In Fantastic Island's app process, MediaRemote may return nil for Podcasts
    // metadata while still accepting transport commands. A single Apple-signed
    // Swift helper keeps the now-playing read path alive without respawning per poll.
    private actor SwiftHelper {
        static let shared = SwiftHelper()

        private static let snapshotCommand = "snapshot"
        private static let quitCommand = "quit"
        private static let requestTimeout: Duration = .seconds(3)
        private static let executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        private static let source = #"""
        import Dispatch
        import Foundation

        typealias GetStringCallback = @convention(block) (String?) -> Void
        typealias GetBoolCallback = @convention(block) (Bool) -> Void
        typealias GetInfoCallback = @convention(block) ([AnyHashable: Any]?) -> Void
        typealias GetStringFunction = @convention(c) (DispatchQueue, @escaping GetStringCallback) -> Void
        typealias GetBoolFunction = @convention(c) (DispatchQueue, @escaping GetBoolCallback) -> Void
        typealias GetInfoFunction = @convention(c) (DispatchQueue, @escaping GetInfoCallback) -> Void

        let mediaRemoteHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

        func loadFunction<T>(_ symbol: String, as type: T.Type) -> T? {
            guard let mediaRemoteHandle,
                  let pointer = dlsym(mediaRemoteHandle, symbol) else {
                return nil
            }

            return unsafeBitCast(pointer, to: type)
        }

        func loadStringConstant(_ symbol: String) -> String {
            guard let mediaRemoteHandle,
                  let pointer = dlsym(mediaRemoteHandle, symbol) else {
                return symbol
            }

            return pointer.assumingMemoryBound(to: CFString.self).pointee as String
        }

        let getNowPlayingApplicationDisplayID = loadFunction(
            "MRMediaRemoteGetNowPlayingApplicationDisplayID",
            as: GetStringFunction.self
        )
        let getNowPlayingApplicationIsPlaying = loadFunction(
            "MRMediaRemoteGetNowPlayingApplicationIsPlaying",
            as: GetBoolFunction.self
        )
        let getNowPlayingInfo = loadFunction(
            "MRMediaRemoteGetNowPlayingInfo",
            as: GetInfoFunction.self
        )

        let titleKey = loadStringConstant("kMRMediaRemoteNowPlayingInfoTitle")
        let artistKey = loadStringConstant("kMRMediaRemoteNowPlayingInfoArtist")
        let albumKey = loadStringConstant("kMRMediaRemoteNowPlayingInfoAlbum")
        let durationKey = loadStringConstant("kMRMediaRemoteNowPlayingInfoDuration")
        let elapsedKey = loadStringConstant("kMRMediaRemoteNowPlayingInfoElapsedTime")
        let calculatedElapsedKey = loadStringConstant("kMRMediaRemoteNowPlayingInfoCalculatedElapsedTime")
        let playbackRateKey = loadStringConstant("kMRMediaRemoteNowPlayingInfoPlaybackRate")
        let timestampKey = loadStringConstant("kMRMediaRemoteNowPlayingInfoTimestamp")
        let artworkDataKey = loadStringConstant("kMRMediaRemoteNowPlayingInfoArtworkData")
        let artworkURLKey = loadStringConstant("kMRMediaRemoteNowPlayingInfoArtworkURL")
        var lastArtworkIdentity: String?

        func stringValue(_ key: String, in info: [AnyHashable: Any]) -> String? {
            info[key] as? String
        }

        func doubleValue(_ key: String, in info: [AnyHashable: Any]) -> Double? {
            if let doubleValue = info[key] as? Double {
                return doubleValue
            }

            return (info[key] as? NSNumber)?.doubleValue
        }

        func dateValue(_ key: String, in info: [AnyHashable: Any]) -> Date? {
            if let date = info[key] as? Date {
                return date
            }

            if let date = info[key] as? NSDate {
                return date as Date
            }

            return nil
        }

        func clampedElapsed(_ elapsed: TimeInterval, duration: TimeInterval) -> TimeInterval {
            let lowerBoundedElapsed = max(elapsed, 0)
            guard duration > 0 else {
                return lowerBoundedElapsed
            }

            return min(lowerBoundedElapsed, duration)
        }

        func elapsedTime(in info: [AnyHashable: Any], duration: TimeInterval, playbackRate: Double?) -> TimeInterval {
            if let calculatedElapsed = doubleValue(calculatedElapsedKey, in: info) {
                return clampedElapsed(calculatedElapsed, duration: duration)
            }

            let baseElapsed = doubleValue(elapsedKey, in: info) ?? 0
            guard let timestamp = dateValue(timestampKey, in: info),
                  let playbackRate,
                  playbackRate > 0 else {
                return clampedElapsed(baseElapsed, duration: duration)
            }

            return clampedElapsed(
                baseElapsed + Date().timeIntervalSince(timestamp) * playbackRate,
                duration: duration
            )
        }

        func setJSONValue(_ value: Any?, for key: String, in output: inout [String: Any]) {
            output[key] = value ?? NSNull()
        }

        func snapshotLine() -> String {
            guard let getNowPlayingInfo else {
                return "{}"
            }

            let group = DispatchGroup()
            var displayID: String?
            var isPlaying: Bool?
            var info: [AnyHashable: Any]?

            if let getNowPlayingApplicationDisplayID {
                group.enter()
                getNowPlayingApplicationDisplayID(.global(qos: .userInitiated)) { value in
                    displayID = value
                    group.leave()
                }
            }

            if let getNowPlayingApplicationIsPlaying {
                group.enter()
                getNowPlayingApplicationIsPlaying(.global(qos: .userInitiated)) { value in
                    isPlaying = value
                    group.leave()
                }
            }

            group.enter()
            getNowPlayingInfo(.global(qos: .userInitiated)) { value in
                info = value
                group.leave()
            }

            _ = group.wait(timeout: .now() + 2)

            guard let info else {
                return "{}"
            }

            let duration = doubleValue(durationKey, in: info) ?? 0
            let playbackRate = doubleValue(playbackRateKey, in: info)
            let title = stringValue(titleKey, in: info)
            let artist = stringValue(artistKey, in: info)
            let album = stringValue(albumKey, in: info)
            let artworkURL = stringValue(artworkURLKey, in: info)
            let artworkIdentity = [
                displayID ?? "",
                title ?? "",
                artist ?? "",
                album ?? "",
                artworkURL ?? "",
            ].joined(separator: "\u{1F}")

            var output: [String: Any] = [:]
            setJSONValue(displayID, for: "displayID", in: &output)
            setJSONValue(title, for: "title", in: &output)
            setJSONValue(artist, for: "artist", in: &output)
            setJSONValue(album, for: "album", in: &output)
            output["duration"] = duration
            output["elapsed"] = elapsedTime(in: info, duration: duration, playbackRate: playbackRate)
            setJSONValue(playbackRate, for: "playbackRate", in: &output)
            setJSONValue(isPlaying, for: "isPlaying", in: &output)
            setJSONValue(artworkURL, for: "artworkURL", in: &output)

            let artworkData: Data? = {
                if let data = info[artworkDataKey] as? Data {
                    return data
                }
                if let data = info[artworkDataKey] as? NSData {
                    return data as Data
                }
                return nil
            }()

            if artworkIdentity != lastArtworkIdentity,
               let artworkData,
               !artworkData.isEmpty {
                output["artworkDataBase64"] = artworkData.base64EncodedString()
                lastArtworkIdentity = artworkIdentity
            } else {
                output["artworkDataBase64"] = NSNull()
            }

            guard JSONSerialization.isValidJSONObject(output),
                  let data = try? JSONSerialization.data(withJSONObject: output),
                  let line = String(data: data, encoding: .utf8) else {
                return "{}"
            }

            return line
        }

        while let command = readLine() {
            switch command {
            case "snapshot":
                print(snapshotLine())
                fflush(stdout)
            case "quit":
                exit(0)
            default:
                continue
            }
        }
        """#

        private var process: Process?
        private var inputHandle: FileHandle?
        private var outputReadHandle: FileHandle?
        private var errorReadHandle: FileHandle?
        private var outputBuffer = Data()
        private var pendingContinuation: CheckedContinuation<String?, Never>?
        private var pendingRequestID: UUID?

        func snapshotLine() async -> String? {
            guard startIfNeeded() else {
                return nil
            }

            return await requestLine()
        }

        private func startIfNeeded() -> Bool {
            if process?.isRunning == true,
               inputHandle != nil {
                return true
            }

            stop()

            guard FileManager.default.isExecutableFile(atPath: Self.executableURL.path) else {
                return false
            }

            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = Self.executableURL
            process.arguments = ["-e", Self.source]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { [weak self] _ in
                Task { await self?.handleTermination() }
            }

            let outputReadHandle = outputPipe.fileHandleForReading
            outputReadHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                Task { await self?.consumeOutput(data) }
            }

            let errorReadHandle = errorPipe.fileHandleForReading
            errorReadHandle.readabilityHandler = { handle in
                _ = handle.availableData
            }

            do {
                try process.run()
            } catch {
                outputReadHandle.readabilityHandler = nil
                errorReadHandle.readabilityHandler = nil
                return false
            }

            self.process = process
            self.inputHandle = inputPipe.fileHandleForWriting
            self.outputReadHandle = outputReadHandle
            self.errorReadHandle = errorReadHandle
            return true
        }

        private func requestLine() async -> String? {
            guard pendingContinuation == nil,
                  let inputHandle else {
                return nil
            }

            return await withCheckedContinuation { continuation in
                let requestID = UUID()
                pendingContinuation = continuation
                pendingRequestID = requestID

                do {
                    try inputHandle.write(contentsOf: Data("\(Self.snapshotCommand)\n".utf8))
                } catch {
                    resolvePending(requestID: requestID, with: nil)
                    stop()
                    return
                }

                Task { [weak self] in
                    try? await Task.sleep(for: Self.requestTimeout)
                    await self?.resolvePending(requestID: requestID, with: nil)
                }
            }
        }

        private func consumeOutput(_ data: Data) {
            guard !data.isEmpty else {
                handleTermination()
                return
            }

            outputBuffer.append(data)
            let newline = Data([0x0A])
            while let range = outputBuffer.firstRange(of: newline) {
                let lineData = outputBuffer.subdata(in: outputBuffer.startIndex..<range.lowerBound)
                outputBuffer.removeSubrange(outputBuffer.startIndex..<range.upperBound)
                resolvePending(with: String(data: lineData, encoding: .utf8))
            }
        }

        private func resolvePending(requestID: UUID? = nil, with line: String?) {
            if let requestID,
               pendingRequestID != requestID {
                return
            }

            guard let continuation = pendingContinuation else {
                return
            }

            pendingContinuation = nil
            pendingRequestID = nil
            continuation.resume(returning: line)
        }

        private func handleTermination() {
            resolvePending(with: nil)
            stop()
        }

        private func stop() {
            outputReadHandle?.readabilityHandler = nil
            errorReadHandle?.readabilityHandler = nil

            if process?.isRunning == true {
                try? inputHandle?.write(contentsOf: Data("\(Self.quitCommand)\n".utf8))
                process?.terminate()
            }

            process = nil
            inputHandle = nil
            outputReadHandle = nil
            errorReadHandle = nil
            outputBuffer = Data()
            pendingRequestID = nil
        }
    }

    private let getNowPlayingApplicationDisplayID: GetStringFunction?
    private let getNowPlayingApplicationIsPlaying: GetBoolFunction?
    private let getNowPlayingInfo: GetInfoFunction?
    private let sendCommand: SendCommandFunction?
    private let setElapsedTime: SetElapsedTimeFunction?
    private let titleKey: String
    private let artistKey: String
    private let albumKey: String
    private let durationKey: String
    private let elapsedKey: String
    private let calculatedElapsedKey: String
    private let playbackRateKey: String
    private let timestampKey: String
    private let artworkDataKey: String
    private let artworkURLKey: String

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )

        getNowPlayingApplicationDisplayID = Self.loadFunction(
            "MRMediaRemoteGetNowPlayingApplicationDisplayID",
            from: handle,
            as: GetStringFunction.self
        )
        getNowPlayingApplicationIsPlaying = Self.loadFunction(
            "MRMediaRemoteGetNowPlayingApplicationIsPlaying",
            from: handle,
            as: GetBoolFunction.self
        )
        getNowPlayingInfo = Self.loadFunction(
            "MRMediaRemoteGetNowPlayingInfo",
            from: handle,
            as: GetInfoFunction.self
        )
        sendCommand = Self.loadFunction(
            "MRMediaRemoteSendCommand",
            from: handle,
            as: SendCommandFunction.self
        )
        setElapsedTime = Self.loadFunction(
            "MRMediaRemoteSetElapsedTime",
            from: handle,
            as: SetElapsedTimeFunction.self
        )

        titleKey = Self.loadStringConstant("kMRMediaRemoteNowPlayingInfoTitle", from: handle)
        artistKey = Self.loadStringConstant("kMRMediaRemoteNowPlayingInfoArtist", from: handle)
        albumKey = Self.loadStringConstant("kMRMediaRemoteNowPlayingInfoAlbum", from: handle)
        durationKey = Self.loadStringConstant("kMRMediaRemoteNowPlayingInfoDuration", from: handle)
        elapsedKey = Self.loadStringConstant("kMRMediaRemoteNowPlayingInfoElapsedTime", from: handle)
        calculatedElapsedKey = Self.loadStringConstant("kMRMediaRemoteNowPlayingInfoCalculatedElapsedTime", from: handle)
        playbackRateKey = Self.loadStringConstant("kMRMediaRemoteNowPlayingInfoPlaybackRate", from: handle)
        timestampKey = Self.loadStringConstant("kMRMediaRemoteNowPlayingInfoTimestamp", from: handle)
        artworkDataKey = Self.loadStringConstant("kMRMediaRemoteNowPlayingInfoArtworkData", from: handle)
        artworkURLKey = Self.loadStringConstant("kMRMediaRemoteNowPlayingInfoArtworkURL", from: handle)
    }

    func snapshot(for sourceKind: PlayerSourceKind) async -> Snapshot? {
        if let directSnapshot = await directSnapshot(for: sourceKind) {
            return directSnapshot
        }

        guard let helperLine = await SwiftHelper.shared.snapshotLine() else {
            return nil
        }

        return Self.snapshot(fromHelperLine: helperLine, sourceKind: sourceKind)
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        guard let sendCommand else {
            return false
        }

        sendCommand(command.rawValue, nil)
        return true
    }

    @discardableResult
    func seek(to elapsed: TimeInterval) -> Bool {
        guard elapsed.isFinite, let setElapsedTime else {
            return false
        }

        setElapsedTime(elapsed)
        return true
    }

    private func directSnapshot(for sourceKind: PlayerSourceKind) async -> Snapshot? {
        async let displayID = nowPlayingApplicationDisplayID()
        async let info = nowPlayingInfo()

        let resolvedDisplayID = await displayID
        guard sourceKind == .system
            || resolvedDisplayID == nil
            || resolvedDisplayID == sourceKind.bundleIdentifier,
              let info = await info else {
            return nil
        }

        let playbackRate = doubleValue(for: playbackRateKey, in: info)
        let duration = doubleValue(for: durationKey, in: info) ?? 0
        let isPlayingFallback: Bool?
        if playbackRate == nil {
            isPlayingFallback = await nowPlayingApplicationIsPlaying()
        } else {
            isPlayingFallback = nil
        }

        let artworkData = dataValue(for: artworkDataKey, in: info)

        return Self.makeSnapshot(
            sourceKind: sourceKind,
            displayID: resolvedDisplayID,
            title: stringValue(for: titleKey, in: info),
            artist: stringValue(for: artistKey, in: info),
            album: stringValue(for: albumKey, in: info),
            duration: duration,
            elapsed: elapsedTime(in: info, duration: duration, playbackRate: playbackRate),
            playbackRate: playbackRate,
            isPlayingFallback: isPlayingFallback,
            artworkURL: stringValue(for: artworkURLKey, in: info).flatMap(URL.init(string:)),
            artworkData: artworkData,
            artworkImage: nil,
            timestampDate: dateValue(for: timestampKey, in: info) ?? Date()
        )
    }

    private static func snapshot(fromHelperLine line: String, sourceKind: PlayerSourceKind) -> Snapshot? {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONDecoder().decode(HelperPayload.self, from: data) else {
            return nil
        }

        let artworkImage = payload.artworkDataBase64
            .flatMap(playerArtworkData)
            .flatMap(playerDecodedArtworkImage)

        return makeSnapshot(
            sourceKind: sourceKind,
            displayID: payload.displayID,
            title: payload.title,
            artist: payload.artist,
            album: payload.album,
            duration: payload.duration ?? 0,
            elapsed: payload.elapsed ?? 0,
            playbackRate: payload.playbackRate,
            isPlayingFallback: payload.isPlaying,
            artworkURL: payload.artworkURL.flatMap(URL.init(string:)),
            artworkImage: artworkImage,
            timestampDate: payload.timestamp.flatMap(ISO8601DateFormatter().date(from:)) ?? Date()
        )
    }

    private static func makeSnapshot(
        sourceKind: PlayerSourceKind,
        displayID: String?,
        title: String?,
        artist: String?,
        album: String?,
        duration: TimeInterval,
        elapsed: TimeInterval,
        playbackRate: Double?,
        isPlayingFallback: Bool?,
        artworkURL: URL?,
        artworkData: Data? = nil,
        artworkImage: NSImage?,
        timestampDate: Date = Date()
    ) -> Snapshot? {
        if sourceKind != .system,
           let displayID,
           displayID != sourceKind.bundleIdentifier {
            return nil
        }

        let resolvedDuration = duration.isFinite ? max(0, duration) : 0
        let title = nilIfEmpty(title)
        let artist = nilIfEmpty(artist)
        let album = nilIfEmpty(album)

        let track: PlayerTrackMetadata?
        if let title {
            track = PlayerTrackMetadata(
                title: title,
                artist: artist ?? "Unknown Podcast",
                album: album,
                duration: resolvedDuration,
                elapsed: clampedElapsed(elapsed, duration: resolvedDuration),
                artworkURL: artworkURL
            )
        } else {
            track = nil
        }

        let isPlaying = playbackRate.map { $0 > 0 } ?? isPlayingFallback ?? false
        let playbackStatus: PlayerPlaybackStatus
        if isPlaying {
            playbackStatus = .playing
        } else if let _ = track {
            playbackStatus = .paused
        } else {
            playbackStatus = .stopped
        }

        return Snapshot(
            applicationBundleIdentifier: displayID,
            applicationDisplayName: applicationDisplayName(for: displayID),
            playbackStatus: playbackStatus,
            track: track,
            artworkData: artworkData,
            artworkImage: artworkImage,
            timestampDate: timestampDate,
            playbackRate: playbackRate ?? (isPlaying ? 1 : 0)
        )
    }

    private static func applicationDisplayName(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return nil
        }

        if let runningApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first,
           let localizedName = runningApplication.localizedName,
           !localizedName.isEmpty {
            return localizedName
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return bundleIdentifier
        }

        return Bundle(url: applicationURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: applicationURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundleIdentifier
    }

    private func nowPlayingApplicationDisplayID() async -> String? {
        guard let getNowPlayingApplicationDisplayID else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            getNowPlayingApplicationDisplayID(.global(qos: .userInitiated)) { displayID in
                box.resume(returning: displayID)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
                box.resume(returning: nil)
            }
        }
    }

    private func nowPlayingApplicationIsPlaying() async -> Bool {
        guard let getNowPlayingApplicationIsPlaying else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            getNowPlayingApplicationIsPlaying(.global(qos: .userInitiated)) { isPlaying in
                box.resume(returning: isPlaying)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
                box.resume(returning: false)
            }
        }
    }

    private func nowPlayingInfo() async -> [AnyHashable: Any]? {
        guard let getNowPlayingInfo else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            getNowPlayingInfo(.global(qos: .userInitiated)) { info in
                box.resume(returning: info)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
                box.resume(returning: nil)
            }
        }
    }

    private func stringValue(for key: String, in info: [AnyHashable: Any]) -> String? {
        info[key] as? String
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func doubleValue(for key: String, in info: [AnyHashable: Any]) -> Double? {
        if let doubleValue = info[key] as? Double {
            return doubleValue
        }

        return (info[key] as? NSNumber)?.doubleValue
    }

    private func dateValue(for key: String, in info: [AnyHashable: Any]) -> Date? {
        if let date = info[key] as? Date {
            return date
        }

        if let date = info[key] as? NSDate {
            return date as Date
        }

        return nil
    }

    private func elapsedTime(
        in info: [AnyHashable: Any],
        duration: TimeInterval,
        playbackRate: Double?
    ) -> TimeInterval {
        if let calculatedElapsed = doubleValue(for: calculatedElapsedKey, in: info) {
            return Self.clampedElapsed(calculatedElapsed, duration: duration)
        }

        let baseElapsed = doubleValue(for: elapsedKey, in: info) ?? 0
        guard let timestamp = dateValue(for: timestampKey, in: info),
              let playbackRate,
              playbackRate > 0 else {
            return Self.clampedElapsed(baseElapsed, duration: duration)
        }

        return Self.clampedElapsed(
            baseElapsed + Date().timeIntervalSince(timestamp) * playbackRate,
            duration: duration
        )
    }

    private static func clampedElapsed(_ elapsed: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let lowerBoundedElapsed = max(elapsed, 0)
        guard duration > 0 else {
            return lowerBoundedElapsed
        }

        return min(lowerBoundedElapsed, duration)
    }

    private func imageValue(for key: String, in info: [AnyHashable: Any]) -> NSImage? {
        if let image = info[key] as? NSImage {
            return image
        }

        let data: Data?
        if let value = info[key] as? Data {
            data = value
        } else if let value = info[key] as? NSData {
            data = value as Data
        } else {
            data = nil
        }

        guard let data, !data.isEmpty else { return nil }
        return playerDecodedArtworkImage(from: data)
    }

    private func dataValue(for key: String, in info: [AnyHashable: Any]) -> Data? {
        if let data = info[key] as? Data {
            return data
        }

        if let data = info[key] as? NSData {
            return data as Data
        }

        return nil
    }

    private static func loadFunction<T>(
        _ symbol: String,
        from handle: UnsafeMutableRawPointer?,
        as type: T.Type
    ) -> T? {
        guard let handle,
              let pointer = dlsym(handle, symbol) else {
            return nil
        }

        return unsafeBitCast(pointer, to: type)
    }

    private static func loadStringConstant(
        _ symbol: String,
        from handle: UnsafeMutableRawPointer?
    ) -> String {
        guard let handle,
              let pointer = dlsym(handle, symbol) else {
            return symbol
        }

        let value = pointer.assumingMemoryBound(to: CFString.self).pointee
        return value as String
    }
}

private actor PlayerMediaRemoteAdapter {
    static let shared = PlayerMediaRemoteAdapter()

    private struct Update: Decodable {
        let diff: Bool?
        let payload: Payload
    }

    private struct Payload: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let durationMicros: Double?
        let elapsedTime: Double?
        let elapsedTimeMicros: Double?
        let elapsedTimeNow: Double?
        let elapsedTimeNowMicros: Double?
        let timestampEpochMicros: Double?
        let timestamp: String?
        let playbackRate: Double?
        let playing: Bool?
        let shuffleMode: Int?
        let repeatMode: Int?
        let artworkData: String?
        let artworkURL: String?
        let parentApplicationBundleIdentifier: String?
        let bundleIdentifier: String?
    }

    private var process: Process?
    private var outputHandle: FileHandle?
    private var pendingContinuation: CheckedContinuation<PlayerMediaRemoteBridge.Snapshot?, Never>?
    private var outputBuffer = Data()
    private var latestSnapshot: PlayerMediaRemoteBridge.Snapshot?
    private var snapshotRevision: UInt64 = 0
    private var waitingForFreshSnapshot = false
    // boring.notch keeps one permanent JSON-lines reader and publishes every
    // MediaRemote update to its UI. Keep the same ownership model here: the
    // stream, rather than a poll or a paused-session cache, is authoritative.
    private var updateContinuations: [UUID: AsyncStream<PlayerMediaRemoteBridge.Snapshot?>.Continuation] = [:]

    func send(command: Int) async -> Bool {
        await runCommand(function: "send", argument: String(command))
    }

    func seek(to elapsed: TimeInterval) async -> Bool {
        guard elapsed.isFinite else { return false }
        let positionMicros = max(0, Int64((elapsed * 1_000_000).rounded()))
        return await runCommand(function: "seek", argument: String(positionMicros))
    }

    func toggleShuffle() async -> Bool {
        let nextMode = latestSnapshot?.shuffleMode == .on ? 1 : 3
        let didSend = await runCommand(function: "shuffle", argument: String(nextMode))
        guard didSend else { return false }
        updateModesLocally(
            shuffleMode: nextMode == 1 ? .off : .on,
            repeatMode: nil
        )
        return true
    }

    func cycleRepeat() async -> Bool {
        let nextMode: Int
        switch latestSnapshot?.repeatMode {
        case .all:
            nextMode = 2
        case .one:
            nextMode = 1
        case .off, .unsupported, nil:
            nextMode = 3
        }
        let didSend = await runCommand(function: "repeat", argument: String(nextMode))
        guard didSend else { return false }
        let updatedRepeatMode: PlayerRepeatMode
        switch nextMode {
        case 2: updatedRepeatMode = .one
        case 3: updatedRepeatMode = .all
        default: updatedRepeatMode = .off
        }
        updateModesLocally(shuffleMode: nil, repeatMode: updatedRepeatMode)
        return true
    }

    /// The player refresh path must never wait for a second stream event. The
    /// adapter is already a persistent MediaRemote stream, so the latest
    /// decoded snapshot is the same low-latency source used by boring.notch.
    func snapshot() async -> PlayerMediaRemoteBridge.Snapshot? {
        guard startIfNeeded() else { return nil }
        return latestSnapshot
    }

    func updates() -> AsyncStream<PlayerMediaRemoteBridge.Snapshot?> {
        guard startIfNeeded() else {
            return AsyncStream { continuation in
                continuation.yield(nil)
                continuation.finish()
            }
        }

        let identifier = UUID()
        let streamAndContinuation = AsyncStream<PlayerMediaRemoteBridge.Snapshot?>.makeStream()
        updateContinuations[identifier] = streamAndContinuation.continuation
        streamAndContinuation.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeUpdateContinuation(identifier) }
        }
        // An immediate value gives a newly created Player view the current
        // state, then every later title/artwork/status update is pushed.
        streamAndContinuation.continuation.yield(latestSnapshot)
        return streamAndContinuation.stream
    }

    /// Artwork may arrive in a follow-up diff. This bounded wait is reserved
    /// for the background artwork task and is intentionally not used by the
    /// main playback-state refresh path.
    func freshSnapshot(maximumWait: Duration = .milliseconds(280)) async -> PlayerMediaRemoteBridge.Snapshot? {
        guard startIfNeeded() else { return nil }

        let cachedSnapshot = latestSnapshot
        let revisionBeforeWait = snapshotRevision
        let resolvedWaitDuration = maximumWait
        waitingForFreshSnapshot = cachedSnapshot != nil
        defer {
            waitingForFreshSnapshot = false
        }

        let result = await withTaskGroup(of: PlayerMediaRemoteBridge.Snapshot?.self) { group in
            group.addTask { [weak self] in
                await self?.waitForSnapshot()
            }
            group.addTask {
                try? await Task.sleep(for: resolvedWaitDuration)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        resolve(nil)

        // A short wait lets the stream publish the new browser/media-session
        // event instead of returning the previous track immediately. If the
        // stream did not publish anything during the window, retain the last
        // known snapshot rather than making the Player flicker to empty.
        if let result {
            return result
        }
        if snapshotRevision != revisionBeforeWait {
            return latestSnapshot
        }
        return cachedSnapshot
    }

    private func waitForSnapshot() async -> PlayerMediaRemoteBridge.Snapshot? {
        await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            guard outputHandle != nil else {
                resolve(nil)
                return
            }
        }
    }

    private func startIfNeeded() -> Bool {
        guard process?.isRunning != true else { return true }
        stop()

        guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworkURL = adapterFrameworkURL() else {
            return false
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            scriptURL.path,
            frameworkURL.path,
            "stream",
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleProcessTermination() }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            return false
        }

        self.process = process
        self.outputHandle = outputPipe.fileHandleForReading
        // Keep the MediaRemote stream hot for the whole lifetime of the
        // adapter. The old implementation installed this handler only from
        // waitForSnapshot(), which meant the normal immediate snapshot path
        // never consumed Chrome's later title/artwork/termination updates.
        // Install exactly one outstanding read at a time. Creating a new Task
        // from every readability callback can enqueue MediaRemote diff events
        // out of order when title, artwork and playback-state updates arrive
        // in the same burst. Boring Notch's JSONLinesPipeHandler serializes
        // these reads; armOutputReader() does the same here.
        armOutputReader()
        return true
    }

    private func armOutputReader() {
        guard process?.isRunning == true,
              let outputHandle else {
            return
        }

        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            handle.readabilityHandler = nil
            Task { [weak self] in
                guard let self else { return }
                await self.consume(data)
                await self.armOutputReader()
            }
        }
    }

    private func runCommand(function: String, argument: String) async -> Bool {
        guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworkURL = adapterFrameworkURL() else {
            return false
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkURL.path, function, argument]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
            _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func adapterFrameworkURL() -> URL? {
        if let privateFrameworksPath = Bundle.main.privateFrameworksPath {
            let frameworkURL = URL(fileURLWithPath: privateFrameworksPath)
                .appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
            if FileManager.default.fileExists(atPath: frameworkURL.path) {
                return frameworkURL
            }
        }

        if let frameworkURL = Bundle.main.url(
            forResource: "MediaRemoteAdapter",
            withExtension: "framework"
        ) {
            return frameworkURL
        }

        if let bundleURL = Bundle.main.url(
            forResource: "MediaRemoteAdapter",
            withExtension: "bundle"
        ) {
            return materializeFramework(from: bundleURL)
        }

        // Xcode's synchronized resource group flattens framework bundles into
        // Resources. Recreate the small framework wrapper expected by the
        // upstream Perl launcher when that happens.
        guard let binaryURL = Bundle.main.url(
            forResource: "MediaRemoteAdapter",
            withExtension: nil
        ) else {
            return nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
        let targetURL = directory.appendingPathComponent("MediaRemoteAdapter")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.copyItem(at: binaryURL, to: targetURL)
            }
            return directory
        } catch {
            return nil
        }
    }

    private func materializeFramework(from bundleURL: URL) -> URL? {
        let binaryURL = bundleURL.appendingPathComponent("MediaRemoteAdapter")
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            return nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
        let targetURL = directory.appendingPathComponent("MediaRemoteAdapter")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.copyItem(at: binaryURL, to: targetURL)
            }
            return directory
        } catch {
            return nil
        }
    }

    private func consume(_ data: Data) async {
        guard !data.isEmpty else {
            resolve(nil)
            stop()
            return
        }

        outputBuffer.append(data)
        let newline = Data([0x0A])
        while let range = outputBuffer.firstRange(of: newline) {
            let line = outputBuffer.subdata(in: outputBuffer.startIndex..<range.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex..<range.upperBound)
            guard !line.isEmpty else { continue }
            let lineText = String(data: line, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if lineText?.isEmpty == true || lineText == "null" {
                latestSnapshot = nil
                snapshotRevision &+= 1
                broadcast(nil)
                if waitingForFreshSnapshot {
                    resolve(nil)
                }
                // The adapter can emit an empty marker immediately after the
                // stream starts, before Chrome publishes its Media Session.
                // Do not finish the initial wait here: returning nil makes
                // the caller fall back to a stale Apple Music query. The
                // snapshot timeout still ends the wait when there is truly no
                // active media session.
                continue
            }
            if let snapshot = await snapshot(from: line) {
                // The adapter emits an initial empty payload before the first
                // real Media Session update. Do not cache that placeholder,
                // otherwise snapshot() could keep returning "stopped" before
                // the Chrome live-session event has arrived.
                if snapshot.track == nil {
                    latestSnapshot = nil
                    snapshotRevision &+= 1
                    broadcast(nil)
                    if waitingForFreshSnapshot {
                        resolve(nil)
                    }
                    // Same startup rule as above. A no-track update is a
                    // state reset, not a completed lookup request.
                } else {
                    latestSnapshot = snapshot
                    snapshotRevision &+= 1
                    broadcast(snapshot)
                    resolve(snapshot)
                }
            }
        }
    }

    private func snapshot(from data: Data) async -> PlayerMediaRemoteBridge.Snapshot? {
        // MediaRemote represents a live stream's unknown duration as `inf`.
        // The adapter forwards that value verbatim, which is not valid JSON;
        // one malformed numeric field must not discard the whole Now Playing
        // update (title, source, playback state and artwork are still valid).
        guard let normalizedData = normalizedJSONData(data),
              let update = try? JSONDecoder().decode(Update.self, from: normalizedData) else {
            return nil
        }

        let payload = update.payload
        let isDiff = update.diff ?? false
        let previousSnapshot = latestSnapshot
        let previousTrack = previousSnapshot?.track

        // This is deliberately the same state reconstruction order as
        // boring.notch's NowPlayingController.handleAdapterUpdate(_:). The
        // adapter owns one ordered MediaRemote stream; a `diff` only inherits
        // fields from its immediately preceding stream value. In particular,
        // do not query MediaRemote's global owner here: during an Apple Music
        // pause that separate API can briefly return Apple Music after the
        // stream has already switched to Chrome.
        let title = trimmedValue(payload.title)
            ?? (isDiff ? previousTrack?.title : nil)
        let artist = trimmedValue(payload.artist)
            ?? (isDiff ? previousTrack?.artist : nil)
        let album = trimmedValue(payload.album)
            ?? (isDiff ? previousTrack?.album : nil)

        let durationFromMicros = payload.durationMicros.map { $0 / 1_000_000 }
        let duration = max(
            durationFromMicros
                ?? payload.duration
                ?? (isDiff ? previousTrack?.duration : nil)
                ?? 0,
            0
        )

        let elapsedFromMicros = payload.elapsedTimeNowMicros.map { $0 / 1_000_000 }
            ?? payload.elapsedTimeMicros.map { $0 / 1_000_000 }
        let elapsedFromPayload = elapsedFromMicros
            ?? payload.elapsedTimeNow
            ?? payload.elapsedTime
        let timestampDate = Self.timestampDate(from: payload)
            ?? (isDiff ? previousSnapshot?.timestampDate : nil)
            ?? Date()
        let elapsed: TimeInterval
        if let elapsedFromPayload {
            elapsed = elapsedFromPayload
        } else if isDiff, payload.playing == false,
                  let previousElapsed = previousTrack?.elapsed {
            // Exact Boring Notch behaviour for a pause diff with no elapsed
            // field: first advance the old clock, then freeze it.
            elapsed = previousElapsed
                + max(Date().timeIntervalSince(previousSnapshot?.timestampDate ?? timestampDate), 0)
                    * (previousSnapshot?.playbackRate ?? 1)
        } else {
            elapsed = isDiff ? previousTrack?.elapsed ?? 0 : 0
        }

        let artworkData = payload.artworkData.flatMap(playerArtworkData)
            ?? (isDiff ? previousSnapshot?.artworkData : nil)
        let artworkURL = payload.artworkURL.flatMap(URL.init(string:))
            ?? (isDiff ? previousTrack?.artworkURL : nil)
        let track: PlayerTrackMetadata?
        if let title {
            track = PlayerTrackMetadata(
                title: title,
                artist: artist ?? "Unknown Artist",
                album: album,
                duration: duration,
                elapsed: max(0, min(duration, elapsed)),
                artworkURL: artworkURL
            )
        } else {
            track = nil
        }

        let isPlaying = payload.playing
            ?? (isDiff ? previousSnapshot?.playbackStatus == .playing : false)
        let playbackRate = payload.playbackRate
            ?? (isDiff ? previousSnapshot?.playbackRate : nil)
            ?? 1
        let shuffleMode: PlayerShuffleMode
        if let rawMode = payload.shuffleMode {
            shuffleMode = rawMode == 1 ? .off : .on
        } else if isDiff {
            shuffleMode = previousSnapshot?.shuffleMode ?? .off
        } else {
            shuffleMode = .off
        }
        let repeatMode: PlayerRepeatMode
        if let rawMode = payload.repeatMode {
            switch rawMode {
            case 1: repeatMode = .off
            case 2: repeatMode = .one
            case 3: repeatMode = .all
            default: repeatMode = .off
            }
        } else if isDiff {
            repeatMode = previousSnapshot?.repeatMode ?? .off
        } else {
            repeatMode = .off
        }
        let applicationBundleIdentifier = payload.parentApplicationBundleIdentifier
            ?? payload.bundleIdentifier
            ?? (isDiff ? previousSnapshot?.applicationBundleIdentifier : nil)
        let status: PlayerPlaybackStatus
        if isPlaying {
            status = .playing
        } else if track != nil {
            status = .paused
        } else {
            status = .stopped
        }

        return PlayerMediaRemoteBridge.Snapshot(
            applicationBundleIdentifier: applicationBundleIdentifier,
            applicationDisplayName: applicationDisplayName(for: applicationBundleIdentifier),
            playbackStatus: status,
            track: track,
            artworkData: artworkData,
            // Boring Notch keeps artwork bytes in PlaybackState and decodes
            // them in MusicManager. Do the same: image decoding must never
            // hold up the MediaRemote stream or contaminate a source switch.
            artworkImage: nil,
            shuffleMode: shuffleMode,
            repeatMode: repeatMode,
            timestampDate: timestampDate,
            playbackRate: playbackRate
        )
    }

    private static func timestampDate(from payload: Payload) -> Date? {
        if let timestamp = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: timestamp) {
            return date
        }

        if let epochMicros = payload.timestampEpochMicros,
           epochMicros.isFinite {
            return Date(timeIntervalSince1970: epochMicros / 1_000_000)
        }

        return nil
    }

    private func normalizedJSONData(_ data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }

        // `inf`, `-inf`, `infinity` and `nan` can appear in numeric MediaRemote
        // fields for live streams. JSON has no representation for non-finite
        // numbers, so turn only value positions into null and let Codable use
        // the existing optional fallbacks below.
        let pattern = #"(:\s*)(-?(?:inf(?:inity)?|nan))(?=\s*[,}])"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return data
        }

        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        let normalized = regex.stringByReplacingMatches(
            in: string,
            options: [],
            range: range,
            withTemplate: "$1null"
        )
        return normalized.data(using: .utf8)
    }

    private func applicationDisplayName(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first,
           let name = application.localizedName,
           !name.isEmpty {
            return name
        }
        return bundleIdentifier
    }

    private func trimmedValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value
    }

    private func resolve(_ snapshot: PlayerMediaRemoteBridge.Snapshot?) {
        guard let pendingContinuation else { return }
        self.pendingContinuation = nil
        pendingContinuation.resume(returning: snapshot)
    }

    private func broadcast(_ snapshot: PlayerMediaRemoteBridge.Snapshot?) {
        for continuation in updateContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func updateModesLocally(
        shuffleMode: PlayerShuffleMode?,
        repeatMode: PlayerRepeatMode?
    ) {
        guard let snapshot = latestSnapshot else { return }
        let updatedSnapshot = PlayerMediaRemoteBridge.Snapshot(
            applicationBundleIdentifier: snapshot.applicationBundleIdentifier,
            applicationDisplayName: snapshot.applicationDisplayName,
            playbackStatus: snapshot.playbackStatus,
            track: snapshot.track,
            artworkData: snapshot.artworkData,
            artworkImage: snapshot.artworkImage,
            shuffleMode: shuffleMode ?? snapshot.shuffleMode,
            repeatMode: repeatMode ?? snapshot.repeatMode,
            timestampDate: snapshot.timestampDate,
            playbackRate: snapshot.playbackRate
        )
        latestSnapshot = updatedSnapshot
        snapshotRevision &+= 1
        broadcast(updatedSnapshot)
    }

    private func removeUpdateContinuation(_ identifier: UUID) {
        updateContinuations.removeValue(forKey: identifier)
    }

    private func handleProcessTermination() {
        process = nil
        outputHandle?.readabilityHandler = nil
        outputHandle = nil
        latestSnapshot = nil
        snapshotRevision &+= 1
        broadcast(nil)
        resolve(nil)
    }

    private func stop() {
        outputHandle?.readabilityHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        outputHandle = nil
        outputBuffer.removeAll(keepingCapacity: false)
        latestSnapshot = nil
        snapshotRevision &+= 1
        broadcast(nil)
        resolve(nil)
    }
}

@MainActor
final class PlayerMediaCoordinator {
    private static let artworkThumbnailMaxPixelSize: CGFloat = 192

    private enum AppleEventError {
        static let noError: OSStatus = 0
        static let eventNotPermitted: OSStatus = -1743
        static let wouldRequireUserConsent: OSStatus = -1744
    }

    private enum TransportCommand {
        case previousTrack
        case togglePlayPause
        case nextTrack

        func perform(on source: ScriptSource) {
            switch self {
            case .previousTrack:
                source.previousTrack()
            case .togglePlayPause:
                source.togglePlayPause()
            case .nextTrack:
                source.nextTrack()
            }
        }
    }

    private struct PlayerSnapshot {
        var source: PlayerSourceKind
        var applicationBundleIdentifier: String? = nil
        var applicationDisplayName: String? = nil
        var playbackStatus: PlayerPlaybackStatus
        var track: PlayerTrackMetadata?
        var shuffleMode: PlayerShuffleMode
        var repeatMode: PlayerRepeatMode
        var artworkData: Data? = nil
        var artworkImage: NSImage?
        // Script-backed fallbacks report the position at fetch time, so their
        // render anchor is the fetch instant rather than distantPast.
        var timestampDate: Date = Date()
        var playbackRate: Double = 1
    }

    private struct MediaSessionRecord {
        var snapshot: PlayerSnapshot
        /// The last time this application actually started/resumed playback.
        /// Pausing a session must not move it ahead of a newer browser session.
        var lastActiveAt: Date
    }

    private enum FetchResult {
        case snapshot(PlayerSnapshot)
        case automationIssue(PlayerAutomationIssue)
        case systemSessionUnavailable
        case unavailable
    }

    fileprivate struct AppleScriptExecutionResult {
        let descriptor: NSAppleEventDescriptor?
        let error: NSDictionary?

        var errorCode: Int? {
            error?[NSAppleScript.errorNumber] as? Int
        }

        var stringValue: String? {
            guard let descriptor,
                  descriptor.descriptorType != typeNull else {
                return nil
            }

            let output = (descriptor.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? nil : output
        }
    }

    private struct ScriptSource {
        let kind: PlayerSourceKind
        let fetchState: () async -> FetchResult
        let previousTrack: () -> Void
        let togglePlayPause: () -> Void
        let nextTrack: () -> Void
        let seek: (TimeInterval) -> Void
        let toggleShuffle: () -> Void
        let cycleRepeat: () -> Void
    }

    private struct MusicArtworkPrefetchCandidate {
        let track: PlayerTrackMetadata
        let artworkFileURL: URL?
    }

    private lazy var sources: [ScriptSource] = [
        makeMusicSource(),
        makeSpotifySource(),
        makePodcastsSource(),
        makeSystemNowPlayingSource(),
    ]
    private var lastPreferredSourceKind: PlayerSourceKind?
    private var artworkCache: [String: NSImage] = [:]
    private var artworkCacheOrder: [String] = []
    private var musicArtworkURLCache: [String: URL] = [:]
    private var lastPodcastsSnapshot: PlayerSnapshot?
    private var lastPodcastsSnapshotDate: Date?
    private var mediaSessionRecords: [String: MediaSessionRecord] = [:]
    private let scriptWorker = PlayerAppleScriptWorker()
    private let artworkCacheLimit = 8
    private let launchedCommandDelay: TimeInterval = 0.8
    private let immediateRefreshDelay: TimeInterval = 0.25
    private let launchedRefreshDelay: TimeInterval = 1.15
    private let podcastsSnapshotGraceInterval: TimeInterval = 6

    func fetchCurrentState(preferredSourceKind: PlayerSourceKind?) async -> PlayerNowPlayingState {
        _ = preferredSourceKind
        return nowPlayingState(from: await PlayerMediaRemoteAdapter.shared.snapshot())
    }

    /// Mirrors boring.notch's NowPlayingController: consume one permanent
    /// MediaRemote JSON stream and publish every update directly to the UI.
    /// There is intentionally no fallback selection between paused Music,
    /// Chrome, Spotify or cached records here.
    func systemNowPlayingUpdates() async -> AsyncStream<PlayerNowPlayingState> {
        let snapshots = await PlayerMediaRemoteAdapter.shared.updates()
        let streamAndContinuation = AsyncStream<PlayerNowPlayingState>.makeStream()
        let forwardingTask = Task { @MainActor [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled else {
                    break
                }
                streamAndContinuation.continuation.yield(
                    self?.nowPlayingState(from: snapshot) ?? .empty
                )
            }
            streamAndContinuation.continuation.finish()
        }
        streamAndContinuation.continuation.onTermination = { _ in
            forwardingTask.cancel()
        }
        return streamAndContinuation.stream
    }

    private func shouldKeepPausedSnapshot(_ snapshot: PlayerSnapshot) -> Bool {
        guard snapshot.playbackStatus == .paused,
              snapshot.track != nil else {
            return false
        }

        return isCurrentlyValidSnapshot(snapshot)
    }

    private func isCurrentlyValidSnapshot(_ snapshot: PlayerSnapshot) -> Bool {
        let bundleIdentifier = snapshot.applicationBundleIdentifier
            ?? (snapshot.source == .system ? nil : snapshot.source.bundleIdentifier)
        guard let bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return false
        }

        return !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }

    private func mediaSessionKey(for snapshot: PlayerSnapshot) -> String {
        if let bundleIdentifier = snapshot.applicationBundleIdentifier,
           !bundleIdentifier.isEmpty {
            return "application:\(bundleIdentifier)"
        }

        return "source:\(snapshot.source.rawValue)"
    }

    private func mediaSessionKey(for sourceKind: PlayerSourceKind) -> String {
        if !sourceKind.bundleIdentifier.isEmpty {
            return "application:\(sourceKind.bundleIdentifier)"
        }

        return "source:\(sourceKind.rawValue)"
    }

    private func forgetMediaSession(_ snapshot: PlayerSnapshot) {
        mediaSessionRecords.removeValue(forKey: mediaSessionKey(for: snapshot))
    }

    private func forgetMediaSession(for sourceKind: PlayerSourceKind) {
        mediaSessionRecords.removeValue(forKey: mediaSessionKey(for: sourceKind))
    }

    private func rememberMediaSession(_ snapshot: PlayerSnapshot) {
        let key = mediaSessionKey(for: snapshot)
        let previous = mediaSessionRecords[key]
        var resolvedSnapshot = snapshot
        let isSameTrack = previous?.snapshot.track?.title == snapshot.track?.title
            && previous?.snapshot.track?.artist == snapshot.track?.artist
            && previous?.snapshot.track?.album == snapshot.track?.album
        if resolvedSnapshot.artworkImage == nil, isSameTrack {
            resolvedSnapshot.artworkImage = previous?.snapshot.artworkImage
        }
        if resolvedSnapshot.track?.artworkURL == nil, isSameTrack {
            resolvedSnapshot.track?.artworkURL = previous?.snapshot.track?.artworkURL
        }

        let lastActiveAt: Date
        if resolvedSnapshot.playbackStatus == .playing {
            lastActiveAt = Date()
        } else {
            lastActiveAt = previous?.lastActiveAt ?? Date()
        }

        mediaSessionRecords[key] = MediaSessionRecord(
            snapshot: resolvedSnapshot,
            lastActiveAt: lastActiveAt
        )
    }

    private func purgeDeadMediaSessions() {
        mediaSessionRecords = mediaSessionRecords.filter { _, record in
            isCurrentlyValidSnapshot(record.snapshot)
        }
    }

    private func fetchState(for sourceKind: PlayerSourceKind) async -> PlayerNowPlayingState {
        guard let source = resolvedSource(for: sourceKind) else {
            lastPreferredSourceKind = nil
            return .idleState(source: sourceKind)
        }

        switch await source.fetchState() {
        case let .snapshot(snapshot):
            lastPreferredSourceKind = snapshot.source
            return toState(snapshot)
        case let .automationIssue(issue):
            lastPreferredSourceKind = nil
            return .issueState(issue)
        case .systemSessionUnavailable:
            lastPreferredSourceKind = sourceKind
            return .idleState(source: sourceKind)
        case .unavailable:
            lastPreferredSourceKind = sourceKind
            return .idleState(source: sourceKind)
        }
    }

    func previousTrack(for sourceKind: PlayerSourceKind?) -> TimeInterval? {
        performTransportCommand(.previousTrack, for: sourceKind)
    }

    func togglePlayPause(for sourceKind: PlayerSourceKind?) -> TimeInterval? {
        performTransportCommand(.togglePlayPause, for: sourceKind)
    }

    func nextTrack(for sourceKind: PlayerSourceKind?) -> TimeInterval? {
        performTransportCommand(.nextTrack, for: sourceKind)
    }

    func seek(to elapsed: TimeInterval, for sourceKind: PlayerSourceKind?) {
        resolvedSource(for: sourceKind)?.seek(elapsed)
    }

    func toggleShuffle(for sourceKind: PlayerSourceKind?) {
        resolvedSource(for: sourceKind)?.toggleShuffle()
    }

    func cycleRepeat(for sourceKind: PlayerSourceKind?) {
        resolvedSource(for: sourceKind)?.cycleRepeat()
    }

    func loadArtworkIfNeeded(for state: PlayerNowPlayingState) async -> NSImage? {
        guard let source = state.source,
              let track = state.track else {
            return nil
        }

        // Match boring.notch's NowPlayingController/MusicManager path. For
        // the generic MediaRemote source, artworkData is the authoritative
        // identity and the image is decoded directly from the new bytes. Do
        // not consult the title/artist cache first: the same metadata can be
        // republished with a different cover, and a cached partial image must
        // never win over the current MediaRemote payload.
        if source == .system {
            guard let artworkData = state.artworkData,
                  !artworkData.isEmpty else {
                return nil
            }

            return await Self.decodeArtworkImage(from: artworkData)
        }

        let cacheKey: String
        var remoteArtworkURL: URL?

        switch source {
        case .music:
            cacheKey = musicArtworkCacheKey(for: track)
            remoteArtworkURL = musicArtworkURLCache[cacheKey]
        case .podcasts:
            cacheKey = podcastsArtworkCacheKey(for: track, artworkURL: track.artworkURL)
            remoteArtworkURL = track.artworkURL
        case .spotify:
            cacheKey = spotifyArtworkCacheKey(for: track, artworkURL: track.artworkURL)
            remoteArtworkURL = track.artworkURL
        case .system:
            cacheKey = systemArtworkCacheKey(for: track, artworkURL: track.artworkURL)
            remoteArtworkURL = track.artworkURL
        }

        if let cachedImage = cachedArtworkImage(for: cacheKey) {
            return cachedImage
        }

        // This is the normal Apple Music and browser Media Session path. The
        // cover bytes already came from MediaRemote, so decode them first on
        // the background image pipeline instead of waiting for a network URL.
        if let artworkData = state.artworkData,
           !artworkData.isEmpty,
           let image = await Self.decodeArtworkImage(from: artworkData) {
            storeArtwork(image, for: cacheKey)
            return image
        }

        // The generic MediaRemote controller in boring.notch does not try to
        // download a second copy of browser/Apple Music artwork. If the
        // provider did not publish artworkData, the UI keeps its last valid
        // image for the same track or shows the active app icon fallback.
        // This prevents a slow URL request from reintroducing stale artwork.
        let resolvedArtworkURL: URL?
        switch source {
        case .music:
            if let remoteArtworkURL {
                resolvedArtworkURL = remoteArtworkURL
            } else {
                if let localArtworkImage = await loadMusicArtworkFromCurrentTrack() {
                    storeArtwork(localArtworkImage, for: cacheKey)
                    return localArtworkImage
                }

                resolvedArtworkURL = await Self.lookupMusicArtworkURL(for: track)
                if let resolvedArtworkURL {
                    musicArtworkURLCache[cacheKey] = resolvedArtworkURL
                }
            }
        case .podcasts:
            resolvedArtworkURL = remoteArtworkURL
        case .spotify:
            resolvedArtworkURL = remoteArtworkURL
        case .system:
            resolvedArtworkURL = remoteArtworkURL
        }

        guard let resolvedArtworkURL,
              let image = await Self.loadArtworkImage(from: resolvedArtworkURL) else {
            return nil
        }

        storeArtwork(image, for: cacheKey)
        return image
    }

    func prefetchUpcomingArtwork(after state: PlayerNowPlayingState, limit: Int) async {
        guard state.source == .music,
              state.shuffleMode == .off,
              state.track != nil,
              limit > 0 else {
            return
        }

        let candidates = await loadUpcomingMusicArtworkCandidates(limit: limit)
        guard !candidates.isEmpty else {
            return
        }

        let artworkDirectories = Set(candidates.compactMap { $0.artworkFileURL?.deletingLastPathComponent() })
        defer {
            for directory in artworkDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        for candidate in candidates {
            let cacheKey = musicArtworkCacheKey(for: candidate.track)
            guard cachedArtworkImage(for: cacheKey) == nil else {
                continue
            }

            if let artworkFileURL = candidate.artworkFileURL,
               let data = try? Data(contentsOf: artworkFileURL),
               !data.isEmpty,
               let image = await Self.decodeArtworkImage(from: data) {
                storeArtwork(image, for: cacheKey)
                continue
            }

            if musicArtworkURLCache[cacheKey] == nil,
               let artworkURL = await Self.lookupMusicArtworkURL(for: candidate.track) {
                musicArtworkURLCache[cacheKey] = artworkURL
                if let image = await Self.loadArtworkImage(from: artworkURL) {
                    storeArtwork(image, for: cacheKey)
                }
            }
        }
    }

    nonisolated static func automationPermissionStatus(
        for sourceKind: PlayerSourceKind?,
        askUserIfNeeded: Bool
    ) -> OSStatus {
        guard let sourceKind,
              isApplicationRunning(bundleIdentifier: sourceKind.bundleIdentifier) else {
            return OSStatus(procNotFound)
        }

        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: sourceKind.bundleIdentifier)
        return AEDeterminePermissionToAutomateTarget(
            targetDescriptor.aeDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }

    nonisolated static func determineAutomationPermission(
        for sourceKind: PlayerSourceKind?,
        askUserIfNeeded: Bool
    ) -> OSStatus {
        automationPermissionStatus(for: sourceKind, askUserIfNeeded: askUserIfNeeded)
    }

    @discardableResult
    func activateSourceApplication(for sourceKind: PlayerSourceKind?) -> Bool {
        guard let sourceKind else {
            return false
        }

        if let runningApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: sourceKind.bundleIdentifier)
            .first {
            return runningApplication.activate(options: [.activateAllWindows])
        }

        return Self.launchApplication(bundleIdentifier: sourceKind.bundleIdentifier)
    }

    private func resolvedSource(for sourceKind: PlayerSourceKind?) -> ScriptSource? {
        guard let sourceKind else {
            return nil
        }

        return sources.first { $0.kind == sourceKind }
    }

    private func resolvedTransportSource(for activeSourceKind: PlayerSourceKind?) -> ScriptSource? {
        if let activeSource = resolvedSource(for: activeSourceKind) {
            return activeSource
        }

        let installedControllableSources = PlayerSourceRegistry.installedControllableSources()
        guard let defaultSourceKind = PlayerModuleSettings.resolvedDefaultSource(
            installedControllableSources: installedControllableSources
        ) else {
            return nil
        }

        return resolvedSource(for: defaultSourceKind)
    }

    private func performTransportCommand(
        _ command: TransportCommand,
        for activeSourceKind: PlayerSourceKind?
    ) -> TimeInterval? {
        guard let targetSource = resolvedTransportSource(for: activeSourceKind) else {
            return nil
        }

        // The generic MediaRemote source has no application bundle identifier.
        // It must receive the command directly instead of going through the
        // launch-and-check path used by AppleScript-backed applications.
        if targetSource.kind == .system {
            command.perform(on: targetSource)
            return immediateRefreshDelay
        }

        if Self.isApplicationRunning(bundleIdentifier: targetSource.kind.bundleIdentifier) {
            command.perform(on: targetSource)
            return immediateRefreshDelay
        }

        guard Self.launchApplication(bundleIdentifier: targetSource.kind.bundleIdentifier) else {
            return nil
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(launchedCommandDelay * 1000)))
            command.perform(on: targetSource)
        }
        return launchedRefreshDelay
    }

    private func toState(_ snapshot: PlayerSnapshot) -> PlayerNowPlayingState {
        PlayerNowPlayingState(
            source: snapshot.source,
            applicationBundleIdentifier: snapshot.applicationBundleIdentifier,
            applicationDisplayName: snapshot.applicationDisplayName,
            playbackStatus: snapshot.playbackStatus,
            track: snapshot.track,
            shuffleMode: snapshot.shuffleMode,
            repeatMode: snapshot.repeatMode,
            artworkData: snapshot.artworkData,
            artworkImage: snapshot.artworkImage,
            timestampDate: snapshot.timestampDate,
            playbackRate: snapshot.playbackRate,
            automationIssue: nil
        )
    }

    private func prioritizedSources(
        frontmostBundleID: String?,
        preferredSourceKind: PlayerSourceKind?
    ) -> [ScriptSource] {
        var ordered: [ScriptSource] = []

        // Probe the persistent MediaRemote stream first. It is the only
        // source that can observe browser Media Sessions consistently, and it
        // also prevents a stale Apple Music AppleScript snapshot from hiding
        // an actively playing Chrome session. Known native players are
        // filtered back to their richer scripted sources below.
        if let systemSource = sources.first(where: { $0.kind == .system }) {
            appendSourceIfNeeded(systemSource, to: &ordered)
        }

        if let preferredSourceKind,
           let preferredSource = sources.first(where: { $0.kind == preferredSourceKind }),
           frontmostBundleID == nil
                || preferredSourceKind == .system
                || preferredSource.kind.bundleIdentifier == frontmostBundleID {
            ordered.append(preferredSource)
        }

        if let frontmostBundleID,
           let frontmostSource = sources.first(where: { $0.kind.bundleIdentifier == frontmostBundleID }) {
            appendSourceIfNeeded(frontmostSource, to: &ordered)
        }

        if let lastPreferredSourceKind,
           let preferredSource = sources.first(where: { $0.kind == lastPreferredSourceKind }),
           !ordered.contains(where: { $0.kind == preferredSource.kind }) {
            appendSourceIfNeeded(preferredSource, to: &ordered)
        }

        for source in sources where !ordered.contains(where: { $0.kind == source.kind }) {
            ordered.append(source)
        }

        return ordered
    }

    private func appendSourceIfNeeded(_ source: ScriptSource, to sources: inout [ScriptSource]) {
        if !sources.contains(where: { $0.kind == source.kind }) {
            sources.append(source)
        }
    }

    private func makeMusicSource() -> ScriptSource {
        ScriptSource(
            kind: .music,
            fetchState: { [weak self] in
                await self?.fetchMusicState() ?? .unavailable
            },
            previousTrack: {
                Self.runAppleScript([
                    #"tell application "Music" to previous track"#,
                ])
            },
            togglePlayPause: {
                Self.runAppleScript([
                    #"tell application "Music" to playpause"#,
                ])
            },
            nextTrack: {
                Self.runAppleScript([
                    #"tell application "Music" to next track"#,
                ])
            },
            seek: { elapsed in
                Self.runAppleScript([
                    #"tell application "Music" to set player position to \#(elapsed)"#,
                ])
            },
            toggleShuffle: {
                Self.runAppleScript([
                    #"tell application "Music""#,
                    #"if not running then return"#,
                    #"set shuffle enabled to not shuffle enabled"#,
                    #"end tell"#,
                ])
            },
            cycleRepeat: {
                Self.runAppleScript([
                    #"tell application "Music""#,
                    #"if not running then return"#,
                    #"set currentRepeat to song repeat as text"#,
                    #"if currentRepeat is "off" then"#,
                    #"set song repeat to all"#,
                    #"else if currentRepeat is "all" then"#,
                    #"set song repeat to one"#,
                    #"else"#,
                    #"set song repeat to off"#,
                    #"end if"#,
                    #"end tell"#,
                ])
            }
        )
    }

    private func makeSpotifySource() -> ScriptSource {
        ScriptSource(
            kind: .spotify,
            fetchState: { [weak self] in
                await self?.fetchSpotifyState() ?? .unavailable
            },
            previousTrack: {
                Self.runAppleScript([
                    #"tell application "Spotify" to previous track"#,
                ])
            },
            togglePlayPause: {
                Self.runAppleScript([
                    #"tell application "Spotify" to playpause"#,
                ])
            },
            nextTrack: {
                Self.runAppleScript([
                    #"tell application "Spotify" to next track"#,
                ])
            },
            seek: { elapsed in
                Self.runAppleScript([
                    #"tell application "Spotify" to set player position to \#(elapsed)"#,
                ])
            },
            toggleShuffle: {},
            cycleRepeat: {}
        )
    }

    private func makePodcastsSource() -> ScriptSource {
        ScriptSource(
            kind: .podcasts,
            fetchState: { [weak self] in
                await self?.fetchPodcastsState() ?? .unavailable
            },
            previousTrack: {
                Self.sendPodcastsMediaRemoteCommand(.previousTrack)
            },
            togglePlayPause: {
                Self.sendPodcastsMediaRemoteCommand(.togglePlayPause)
            },
            nextTrack: {
                Self.sendPodcastsMediaRemoteCommand(.nextTrack)
            },
            seek: { _ in },
            toggleShuffle: {},
            cycleRepeat: {}
        )
    }

    private func makeSystemNowPlayingSource() -> ScriptSource {
        ScriptSource(
            kind: .system,
            fetchState: { [weak self] in
                await self?.fetchSystemNowPlayingState() ?? .unavailable
            },
            previousTrack: {
                Task {
                    let sent = await PlayerMediaRemoteAdapter.shared.send(
                        command: PlayerMediaRemoteBridge.Command.previousTrack.rawValue
                    )
                    if !sent {
                        PlayerMediaRemoteBridge.shared.send(.previousTrack)
                    }
                }
            },
            togglePlayPause: {
                Task {
                    let sent = await PlayerMediaRemoteAdapter.shared.send(
                        command: PlayerMediaRemoteBridge.Command.togglePlayPause.rawValue
                    )
                    if !sent {
                        PlayerMediaRemoteBridge.shared.send(.togglePlayPause)
                    }
                }
            },
            nextTrack: {
                Task {
                    let sent = await PlayerMediaRemoteAdapter.shared.send(
                        command: PlayerMediaRemoteBridge.Command.nextTrack.rawValue
                    )
                    if !sent {
                        PlayerMediaRemoteBridge.shared.send(.nextTrack)
                    }
                }
            },
            seek: { elapsed in
                Task {
                    let sent = await PlayerMediaRemoteAdapter.shared.seek(to: elapsed)
                    if !sent {
                        PlayerMediaRemoteBridge.shared.seek(to: elapsed)
                    }
                }
            },
            toggleShuffle: {
                Task {
                    _ = await PlayerMediaRemoteAdapter.shared.toggleShuffle()
                }
            },
            cycleRepeat: {
                Task {
                    _ = await PlayerMediaRemoteAdapter.shared.cycleRepeat()
                }
            }
        )
    }

    private static func sendPodcastsMediaRemoteCommand(_ command: PlayerMediaRemoteBridge.Command) {
        let didActivate = activateApplicationIfRunning(bundleIdentifier: PlayerSourceKind.podcasts.bundleIdentifier)
        guard didActivate else {
            PlayerMediaRemoteBridge.shared.send(command)
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            PlayerMediaRemoteBridge.shared.send(command)
        }
    }

    private func fetchMusicState() async -> FetchResult {
        guard Self.isApplicationRunning(bundleIdentifier: PlayerSourceKind.music.bundleIdentifier) else {
            return .unavailable
        }

        if let permissionIssue = permissionIssue(for: .music) {
            return .automationIssue(permissionIssue)
        }

        let result = await scriptWorker.execute([
            #"tell application "Music""#,
            #"set currentState to player state as text"#,
            #"if currentState is "stopped" then return "stopped""#,
            #"set currentTrack to current track"#,
            #"set trackName to name of currentTrack"#,
            #"set artistName to artist of currentTrack"#,
            #"set albumName to album of currentTrack"#,
            #"set durationSeconds to duration of currentTrack"#,
            #"set elapsedSeconds to player position"#,
            #"set shuffleEnabled to shuffle enabled"#,
            #"set repeatMode to song repeat as text"#,
            #"set AppleScript's text item delimiters to (ASCII character 31)"#,
            #"return {currentState, trackName, artistName, albumName, (durationSeconds as text), (elapsedSeconds as text), (shuffleEnabled as text), repeatMode} as text"#,
            #"end tell"#,
        ])

        guard let output = result.stringValue else {
            return .unavailable
        }

        if output == "stopped" {
            return .snapshot(PlayerSnapshot(
                source: .music,
                playbackStatus: .stopped,
                track: nil,
                shuffleMode: .unsupported,
                repeatMode: .unsupported,
                artworkImage: nil
            ))
        }

        let parts = output.components(separatedBy: "\u{1F}")
        guard parts.count >= 8 else {
            return .unavailable
        }

        let title = fallback(parts[1], default: "Unknown Track")
        let artist = fallback(parts[2], default: "Unknown Artist")
        let album = parts[3].nilIfEmpty
        let duration = Double(parts[4]) ?? 0
        let elapsed = Double(parts[5]) ?? 0

        let cacheKey = [
            "music",
            title,
            artist,
            album ?? "",
        ].joined(separator: "\u{1F}")

        let track = PlayerTrackMetadata(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsed: elapsed,
            artworkURL: musicArtworkURLCache[cacheKey]
        )

        return .snapshot(PlayerSnapshot(
            source: .music,
            playbackStatus: playbackStatus(for: parts[0]),
            track: track,
            shuffleMode: shuffleMode(for: parts[6]),
            repeatMode: repeatMode(for: parts[7]),
            artworkImage: cachedArtworkImage(for: cacheKey)
        ))
    }

    private func fetchPodcastsState() async -> FetchResult {
        guard Self.isApplicationRunning(bundleIdentifier: PlayerSourceKind.podcasts.bundleIdentifier) else {
            lastPodcastsSnapshot = nil
            lastPodcastsSnapshotDate = nil
            return .unavailable
        }

        if let snapshot = await PlayerMediaRemoteBridge.shared.snapshot(for: .podcasts) {
            // MediaRemote can omit the application identifier during a source
            // transition. Do not let that compatibility fallback claim a
            // browser session while Podcasts is merely installed/running.
            guard snapshot.applicationBundleIdentifier == PlayerSourceKind.podcasts.bundleIdentifier else {
                lastPodcastsSnapshot = nil
                lastPodcastsSnapshotDate = nil
                return .unavailable
            }

            var artworkImage = snapshot.artworkImage
            if let track = snapshot.track {
                let cacheKey = podcastsArtworkCacheKey(for: track, artworkURL: track.artworkURL)
                if let cachedImage = cachedArtworkImage(for: cacheKey) {
                    artworkImage = cachedImage
                } else if let snapshotArtworkImage = snapshot.artworkImage {
                    storeArtwork(snapshotArtworkImage, for: cacheKey)
                    artworkImage = snapshotArtworkImage
                }
            }

            let resolvedSnapshot = PlayerSnapshot(
                source: .podcasts,
                applicationBundleIdentifier: snapshot.applicationBundleIdentifier,
                applicationDisplayName: snapshot.applicationDisplayName,
                playbackStatus: snapshot.playbackStatus,
                track: snapshot.track,
                shuffleMode: .unsupported,
                repeatMode: .unsupported,
                artworkImage: artworkImage
            )

            if resolvedSnapshot.track != nil {
                lastPodcastsSnapshot = resolvedSnapshot
                lastPodcastsSnapshotDate = Date()
            } else {
                lastPodcastsSnapshot = nil
                lastPodcastsSnapshotDate = nil
            }

            return .snapshot(resolvedSnapshot)
        }

        if let lastPodcastsSnapshot,
           let lastPodcastsSnapshotDate,
           Date().timeIntervalSince(lastPodcastsSnapshotDate) <= podcastsSnapshotGraceInterval {
            return .snapshot(lastPodcastsSnapshot)
        }

        return .snapshot(PlayerSnapshot(
            source: .podcasts,
            applicationBundleIdentifier: PlayerSourceKind.podcasts.bundleIdentifier,
            applicationDisplayName: PlayerSourceKind.podcasts.displayName,
            playbackStatus: .stopped,
            track: nil,
            shuffleMode: .unsupported,
            repeatMode: .unsupported,
            artworkImage: nil
        ))
    }

    private func fetchSpotifyState() async -> FetchResult {
        guard Self.isApplicationRunning(bundleIdentifier: PlayerSourceKind.spotify.bundleIdentifier) else {
            return .unavailable
        }

        if let permissionIssue = permissionIssue(for: .spotify) {
            return .automationIssue(permissionIssue)
        }

        let result = await scriptWorker.execute([
            #"tell application "Spotify""#,
            #"set currentState to player state as text"#,
            #"if currentState is "stopped" then return "stopped""#,
            #"set currentTrack to current track"#,
            #"set trackName to name of currentTrack"#,
            #"set artistName to artist of currentTrack"#,
            #"set albumName to album of currentTrack"#,
            #"set durationMs to duration of currentTrack"#,
            #"set elapsedSeconds to player position"#,
            #"set artworkURL to artwork url of currentTrack"#,
            #"set AppleScript's text item delimiters to (ASCII character 31)"#,
            #"return {currentState, trackName, artistName, albumName, (durationMs as text), (elapsedSeconds as text), artworkURL} as text"#,
            #"end tell"#,
        ])

        guard let output = result.stringValue else {
            return .unavailable
        }

        if output == "stopped" {
            return .snapshot(PlayerSnapshot(
                source: .spotify,
                playbackStatus: .stopped,
                track: nil,
                shuffleMode: .unsupported,
                repeatMode: .unsupported,
                artworkImage: nil
            ))
        }

        let parts = output.components(separatedBy: "\u{1F}")
        guard parts.count >= 7 else {
            return .unavailable
        }

        let artworkURL = URL(string: parts[6])
        let track = PlayerTrackMetadata(
            title: fallback(parts[1], default: "Unknown Track"),
            artist: fallback(parts[2], default: "Unknown Artist"),
            album: parts[3].nilIfEmpty,
            duration: (Double(parts[4]) ?? 0) / 1000,
            elapsed: Double(parts[5]) ?? 0,
            artworkURL: artworkURL
        )

        return .snapshot(PlayerSnapshot(
            source: .spotify,
            playbackStatus: playbackStatus(for: parts[0]),
            track: track,
            shuffleMode: .unsupported,
            repeatMode: .unsupported,
            artworkImage: cachedArtworkImage(for: spotifyArtworkCacheKey(for: track, artworkURL: artworkURL))
        ))
    }

    private func fetchSystemNowPlayingState() async -> FetchResult {
        guard let snapshot = await PlayerMediaRemoteAdapter.shared.snapshot(),
              let track = snapshot.track,
              !track.title.isEmpty else {
            return .systemSessionUnavailable
        }

        // Keep the MediaRemote session as the single source of truth. Do not
        // discard an active Music/Spotify session and hand selection back to
        // a slower AppleScript snapshot: that is what allowed paused Apple
        // Music metadata to mask a newly playing Chrome session.
        return .snapshot(PlayerSnapshot(
            source: .system,
            applicationBundleIdentifier: snapshot.applicationBundleIdentifier,
            applicationDisplayName: snapshot.applicationDisplayName ?? "Now Playing",
            playbackStatus: snapshot.playbackStatus,
            track: track,
            shuffleMode: snapshot.shuffleMode,
            repeatMode: snapshot.repeatMode,
            artworkData: snapshot.artworkData,
            artworkImage: snapshot.artworkImage,
            timestampDate: snapshot.timestampDate,
            playbackRate: snapshot.playbackRate
        ))
    }

    private func nowPlayingState(
        from snapshot: PlayerMediaRemoteBridge.Snapshot?
    ) -> PlayerNowPlayingState {
        guard let snapshot,
              let track = snapshot.track,
              !track.title.isEmpty else {
            lastPreferredSourceKind = nil
            return .empty
        }

        lastPreferredSourceKind = .system
        return toState(PlayerSnapshot(
            source: .system,
            applicationBundleIdentifier: snapshot.applicationBundleIdentifier,
            applicationDisplayName: snapshot.applicationDisplayName ?? "Now Playing",
            playbackStatus: snapshot.playbackStatus,
            track: track,
            shuffleMode: snapshot.shuffleMode,
            repeatMode: snapshot.repeatMode,
            artworkData: snapshot.artworkData,
            artworkImage: snapshot.artworkImage,
            timestampDate: snapshot.timestampDate,
            playbackRate: snapshot.playbackRate
        ))
    }

    private func permissionIssue(for source: PlayerSourceKind) -> PlayerAutomationIssue? {
        switch Self.automationPermissionStatus(for: source, askUserIfNeeded: false) {
        case AppleEventError.noError:
            return nil
        case OSStatus(procNotFound):
            return nil
        case AppleEventError.eventNotPermitted:
            return .permissionDenied(source: source)
        case AppleEventError.wouldRequireUserConsent:
            return .permissionRequired(source: source)
        default:
            return .permissionRequired(source: source)
        }
    }

    private func playbackStatus(for rawValue: String) -> PlayerPlaybackStatus {
        switch rawValue.lowercased() {
        case "playing":
            return .playing
        case "paused":
            return .paused
        default:
            return .stopped
        }
    }

    private func repeatMode(for rawValue: String) -> PlayerRepeatMode {
        switch rawValue.lowercased() {
        case "all":
            return .all
        case "one":
            return .one
        case "off":
            return .off
        default:
            return .unsupported
        }
    }

    private func shuffleMode(for rawValue: String) -> PlayerShuffleMode {
        switch rawValue.lowercased() {
        case "true":
            return .on
        case "false":
            return .off
        default:
            return .unsupported
        }
    }

    private func fallback(_ value: String, default defaultValue: String) -> String {
        value.nilIfEmpty ?? defaultValue
    }

    private func musicArtworkCacheKey(for track: PlayerTrackMetadata) -> String {
        [
            "music",
            track.title,
            track.artist,
            track.album ?? "",
        ].joined(separator: "\u{1F}")
    }

    private func spotifyArtworkCacheKey(for track: PlayerTrackMetadata, artworkURL: URL?) -> String {
        if let artworkURL {
            return "spotify:\(artworkURL.absoluteString)"
        }

        return [
            "spotify",
            track.title,
            track.artist,
            track.album ?? "",
        ].joined(separator: "\u{1F}")
    }

    private func podcastsArtworkCacheKey(for track: PlayerTrackMetadata, artworkURL: URL?) -> String {
        if let artworkURL {
            return "podcasts:\(artworkURL.absoluteString)"
        }

        return [
            "podcasts",
            track.title,
            track.artist,
            track.album ?? "",
        ].joined(separator: "\u{1F}")
    }

    private func systemArtworkCacheKey(for track: PlayerTrackMetadata, artworkURL: URL?) -> String {
        if let artworkURL {
            return "system:\(artworkURL.absoluteString)"
        }

        return [
            "system",
            track.title,
            track.artist,
            track.album ?? "",
        ].joined(separator: "\u{1F}")
    }

    private func cachedArtworkImage(for key: String) -> NSImage? {
        artworkCache[key]
    }

    private func storeArtwork(_ image: NSImage, for key: String) {
        artworkCache[key] = image
        artworkCacheOrder.removeAll { $0 == key }
        artworkCacheOrder.append(key)

        if artworkCacheOrder.count > artworkCacheLimit,
           let evictedKey = artworkCacheOrder.first {
            artworkCacheOrder.removeFirst()
            artworkCache.removeValue(forKey: evictedKey)
        }
    }

    private static func loadArtworkImage(from url: URL) async -> NSImage? {
        if url.isFileURL,
           let data = try? Data(contentsOf: url) {
            return await decodeArtworkImage(from: data)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5

        guard let data = await fetchData(for: request) else {
            return nil
        }

        return await decodeArtworkImage(from: data)
    }

    private func artworkTracksMatch(_ lhs: PlayerTrackMetadata, _ rhs: PlayerTrackMetadata) -> Bool {
        func normalized(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }

        return normalized(lhs.title) == normalized(rhs.title)
            && normalized(lhs.artist) == normalized(rhs.artist)
    }

    private func loadUpcomingMusicArtworkCandidates(limit: Int) async -> [MusicArtworkPrefetchCandidate] {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FantasticIsland-MusicArtworkPrefetch-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            return []
        }

        let outputDirectoryPath = outputDirectory.path
        let result = await scriptWorker.execute([
            #"set previousDelimiters to AppleScript's text item delimiters"#,
            #"try"#,
            #"tell application "Music""#,
            #"if player state is stopped then error number -128"#,
            #"set playlistRef to current playlist"#,
            #"set currentTrack to current track"#,
            #"set currentDatabaseID to database ID of currentTrack"#,
            #"set currentPersistentID to persistent ID of currentTrack"#,
            #"set trackCount to count of tracks of playlistRef"#,
            #"set currentIndex to 0"#,
            #"repeat with trackIndex from 1 to trackCount"#,
            #"set candidateTrack to track trackIndex of playlistRef"#,
            #"if database ID of candidateTrack is currentDatabaseID and persistent ID of candidateTrack is currentPersistentID then"#,
            #"set currentIndex to trackIndex"#,
            #"exit repeat"#,
            #"end if"#,
            #"end repeat"#,
            #"if currentIndex is 0 then error number -128"#,
            #"set outputRecords to {}"#,
            #"set lastIndex to currentIndex + \#(limit)"#,
            #"if lastIndex > trackCount then set lastIndex to trackCount"#,
            #"repeat with trackIndex from (currentIndex + 1) to lastIndex"#,
            #"set nextTrack to track trackIndex of playlistRef"#,
            #"set trackName to name of nextTrack"#,
            #"set artistName to artist of nextTrack"#,
            #"set albumName to album of nextTrack"#,
            #"set durationSeconds to duration of nextTrack"#,
            #"set artworkPath to """#,
            #"if (count of artworks of nextTrack) > 0 then"#,
            #"set artworkPath to "\#(outputDirectoryPath)/artwork-" & (trackIndex as text) & ".data""#,
            #"set artworkData to raw data of artwork 1 of nextTrack"#,
            #"set outputFile to POSIX file artworkPath"#,
            #"set fileReference to open for access outputFile with write permission"#,
            #"try"#,
            #"set eof fileReference to 0"#,
            #"write artworkData to fileReference"#,
            #"close access fileReference"#,
            #"on error"#,
            #"try"#,
            #"close access fileReference"#,
            #"end try"#,
            #"set artworkPath to """#,
            #"end try"#,
            #"end if"#,
            #"set AppleScript's text item delimiters to (ASCII character 31)"#,
            #"set end of outputRecords to {trackName, artistName, albumName, (durationSeconds as text), artworkPath} as text"#,
            #"end repeat"#,
            #"end tell"#,
            #"set AppleScript's text item delimiters to (ASCII character 30)"#,
            #"set outputText to outputRecords as text"#,
            #"set AppleScript's text item delimiters to previousDelimiters"#,
            #"return outputText"#,
            #"on error"#,
            #"set AppleScript's text item delimiters to previousDelimiters"#,
            #"return """#,
            #"end try"#,
        ])

        guard let output = result.stringValue else {
            try? FileManager.default.removeItem(at: outputDirectory)
            return []
        }

        let candidates = output
            .components(separatedBy: "\u{1E}")
            .compactMap { record -> MusicArtworkPrefetchCandidate? in
                let parts = record.components(separatedBy: "\u{1F}")
                guard parts.count >= 5 else {
                    return nil
                }

                let artworkFileURL = parts[4].isEmpty ? nil : URL(fileURLWithPath: parts[4])
                return MusicArtworkPrefetchCandidate(
                    track: PlayerTrackMetadata(
                        title: fallback(parts[0], default: "Unknown Track"),
                        artist: fallback(parts[1], default: "Unknown Artist"),
                        album: parts[2].nilIfEmpty,
                        duration: Double(parts[3]) ?? 0,
                        elapsed: 0,
                        artworkURL: nil
                    ),
                    artworkFileURL: artworkFileURL
                )
            }

        if candidates.isEmpty {
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        return candidates
    }

    private func loadMusicArtworkFromCurrentTrack() async -> NSImage? {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FantasticIsland-MusicArtwork-\(UUID().uuidString)")

        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let result = await scriptWorker.execute([
            #"tell application "Music""#,
            #"if player state is stopped then return """#,
            #"set currentTrack to current track"#,
            #"if (count of artworks of currentTrack) is 0 then return """#,
            #"set artworkData to raw data of artwork 1 of currentTrack"#,
            #"end tell"#,
            #"set outputFile to POSIX file "\#(fileURL.path)""#,
            #"set fileReference to open for access outputFile with write permission"#,
            #"try"#,
            #"set eof fileReference to 0"#,
            #"write artworkData to fileReference"#,
            #"close access fileReference"#,
            #"on error"#,
            #"try"#,
            #"close access fileReference"#,
            #"end try"#,
            #"return """#,
            #"end try"#,
            #"return POSIX path of outputFile"#,
        ])

        guard result.stringValue != nil,
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return nil
        }

        return await Self.decodeArtworkImage(from: data)
    }

    private static func decodeArtworkImage(from data: Data) async -> NSImage? {
        // boring.notch keeps the raw Data in its playback state and creates
        // NSImage on a user-initiated background queue. Use the same decoder
        // here. Keep the NSImage object returned by AppKit intact and let the
        // SwiftUI renderer use the same square GeometryReader/scaledToFill
        // path as boring.notch.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = autoreleasepool { playerDecodedArtworkImage(from: data) }
                continuation.resume(returning: image)
            }
        }
    }

    @discardableResult
    nonisolated fileprivate static func runAppleScript(_ lines: [String]) -> AppleScriptExecutionResult {
        autoreleasepool {
            runAppleScriptDescriptor(lines)
        }
    }

    nonisolated private static func runAppleScriptDescriptor(_ lines: [String]) -> AppleScriptExecutionResult {
        autoreleasepool {
            let source = lines.joined(separator: "\n")
            guard let script = NSAppleScript(source: source) else {
                return AppleScriptExecutionResult(descriptor: nil, error: nil)
            }

            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            return AppleScriptExecutionResult(descriptor: descriptor, error: error)
        }
    }

    private static func normalizedMetadataValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func lookupMusicArtworkURL(for track: PlayerTrackMetadata) async -> URL? {
        let term = [track.title, track.artist]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else {
            return nil
        }

        let country = Locale.current.region?.identifier ?? "US"
        let candidates = [country, "US"]

        for storefront in candidates {
            guard let url = searchEndpointURL(term: term, storefront: storefront),
                  let data = await fetchData(from: url, timeout: 0.8),
                  let response = try? JSONDecoder().decode(PlayerMusicArtworkSearchResponse.self, from: data),
                  let match = bestSearchArtworkResult(from: response.results, for: track),
                  let rawArtworkURL = match.artworkUrl100,
                  let artworkURL = highResolutionArtworkURL(from: rawArtworkURL) else {
                continue
            }

            return artworkURL
        }

        return nil
    }

    private static func searchEndpointURL(term: String, storefront: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: storefront),
        ]
        return components?.url
    }

    private static func fetchData(from url: URL, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return await fetchData(for: request)
    }

    private static func fetchData(for request: URLRequest) async -> Data? {
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch {
            return nil
        }
    }

    private static func bestSearchArtworkResult(
        from results: [PlayerMusicArtworkSearchResult],
        for track: PlayerTrackMetadata
    ) -> PlayerMusicArtworkSearchResult? {
        if let exactAlbumMatch = results.first(where: { result in
            matchesSearchArtworkResult(result, to: track, requireAlbumMatch: true)
        }) {
            return exactAlbumMatch
        }

        return results.first(where: { result in
            matchesSearchArtworkResult(result, to: track, requireAlbumMatch: false)
        })
    }

    private static func matchesSearchArtworkResult(
        _ result: PlayerMusicArtworkSearchResult,
        to track: PlayerTrackMetadata,
        requireAlbumMatch: Bool
    ) -> Bool {
        let expectedTitle = normalizedMetadataValue(track.title)
        let expectedArtist = normalizedMetadataValue(track.artist)
        let expectedAlbum = normalizedMetadataValue(track.album)

        guard normalizedMetadataValue(result.trackName) == expectedTitle,
              normalizedMetadataValue(result.artistName) == expectedArtist else {
            return false
        }

        guard requireAlbumMatch,
              let expectedAlbum else {
            return true
        }

        return normalizedMetadataValue(result.collectionName) == expectedAlbum
    }

    private static func highResolutionArtworkURL(from rawValue: String) -> URL? {
        let upgraded = rawValue
            .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            .replacingOccurrences(of: "100x100-75", with: "600x600-75")
        return URL(string: upgraded)
    }

    nonisolated private static func isApplicationRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    @discardableResult
    nonisolated private static func activateApplicationIfRunning(bundleIdentifier: String) -> Bool {
        guard let runningApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else {
            return false
        }

        return runningApplication.activate(options: [.activateAllWindows])
    }

    nonisolated private static func launchApplication(bundleIdentifier: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleIdentifier]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

private struct PlayerMusicArtworkSearchResult: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let artworkUrl100: String?
}

private struct PlayerMusicArtworkSearchResponse: Decodable {
    let results: [PlayerMusicArtworkSearchResult]
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
