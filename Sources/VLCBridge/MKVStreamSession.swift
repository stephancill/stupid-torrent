import Foundation

#if os(iOS)
import UIKit
import MobileVLCKit
import Streaming
import TorrentCore

/// Observable playback state for the MKV player.
@MainActor
public final class MKVStreamSession: ObservableObject {
    public enum State: Equatable {
        case idle
        case opening
        case buffering
        case playing
        case paused
        case ended
        case failed
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var durationMs: Int64 = 0
    @Published public private(set) var positionMs: Int64 = 0
    @Published public private(set) var isSeekable = false
    /// Fraction (0...1) of the torrent's pieces that are verified — surfaced while buffering so a
    /// player stalled on a still-downloading/repairing file shows progress instead of an endless
    /// spinner.
    @Published public private(set) var downloadProgress: Double = 0
    @Published public private(set) var audioTracks: [Track] = []
    @Published public private(set) var subtitleTracks: [Track] = []

    public struct Track: Identifiable, Equatable {
        public let id: Int
        public let name: String
        public let isSelected: Bool
    }

    private let torrent: Torrent
    private let player = VLCMediaPlayer()
    private let server: TorrentHTTPServer?
    private let media: VLCMedia
    private var notificationTokens: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    private var lastPositionMs: Int64 = 0

    public init(torrent: Torrent, fileIndex: Int) {
        self.torrent = torrent
        let source = TorrentStreamSourceAdapter(torrent: torrent)
        let name = torrent.fileName(fileIndex)
        let started: TorrentHTTPServer?
        do {
            let s = try TorrentHTTPServer(source: source, fileIndex: fileIndex, path: name)
            s.start()
            started = s
        } catch {
            started = nil
        }
        server = started
        // Loopback bind should never fail; if it does the player errors immediately rather than hang.
        media = started.map { VLCMedia(url: $0.url) } ?? VLCMedia(url: URL(string: "http://127.0.0.1:1/none")!)
        player.media = media
        observe()
    }

    public func attach(drawable: UIView) {
        player.drawable = drawable
        player.play()
        // Poll for state/time instead of relying on VLCMediaPlayer notifications (which don't
        // reliably fire in this VLCKit build). The player is @MainActor; poll on a 250ms loop.
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    self.refreshTime()
                    self.refreshState()
                }
                await self.refreshDownloadProgress()
            }
        }
    }

    public func play() {
        player.play()
    }
    public func pause() { player.pause() }
    public func togglePlayPause() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    public func seek(toMs ms: Int64) {
        player.time = VLCTime(number: NSNumber(value: ms))
    }

    public func selectAudioTrack(_ index: Int) {
        player.currentAudioTrackIndex = Int32(index)
    }

    public func selectSubtitleTrack(_ index: Int) {
        player.currentVideoSubTitleIndex = Int32(index)
    }

    public func teardown() {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens = []
        pollTask?.cancel()
        pollTask = nil
        player.stop()
        server?.stop()
    }

    private func observe() {
        let center = NotificationCenter.default
        let stateToken = center.addObserver(
            forName: NSNotification.Name(VLCMediaPlayerStateChanged), object: player, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshState() }
        }
        let timeToken = center.addObserver(
            forName: NSNotification.Name(VLCMediaPlayerTimeChanged), object: player, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshTime() }
        }
        notificationTokens = [stateToken, timeToken]
    }

    private func refreshState() {
        let now = positionMs
        if player.state == .error {
            state = .failed
        } else if player.state == .ended || (durationMs > 0 && now > 0 && now >= durationMs) {
            state = .ended
        } else if player.isPlaying, now != lastPositionMs {
            // libVLC reports `.buffering` for streaming input even while frames are rendering, so
            // an advancing position is the reliable "actually playing" signal.
            state = .playing
        } else if player.isPlaying {
            // Play was requested but the position is frozen: still loading or stalled on data.
            state = .buffering
        } else {
            switch player.state {
            case .stopped: state = now > 0 && durationMs > 0 && now >= durationMs ? .ended : .idle
            case .opening: state = .opening
            case .buffering: state = .buffering
            case .playing: state = .playing
            case .paused: state = .paused
            case .ended: state = .ended
            case .error: state = .failed
            @unknown default: state = .idle
            }
        }
        lastPositionMs = now
        isSeekable = player.isSeekable
        refreshTracks()
    }

    private func refreshTime() {
        positionMs = player.time.value?.int64Value ?? 0
        durationMs = media.length.value?.int64Value ?? 0
    }

    private func refreshDownloadProgress() async {
        let pieceCount = torrent.metainfo.pieceCount
        guard pieceCount > 0 else { return }
        downloadProgress = Double(await torrent.verifiedCount) / Double(pieceCount)
    }

    private func refreshTracks() {
        let audioIndexes = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.intValue }
        let audioNames = player.audioTrackNames.map { "\($0)" }
        audioTracks = zip(audioIndexes, audioNames).map { index, name in
            Track(id: index, name: name, isSelected: index == Int(player.currentAudioTrackIndex))
        }
        let subtitleIndexes = player.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.intValue }
        let subtitleNames = player.videoSubTitlesNames.map { "\($0)" }
        subtitleTracks = zip(subtitleIndexes, subtitleNames).map { index, name in
            Track(id: index, name: name, isSelected: index == Int(player.currentVideoSubTitleIndex))
        }
    }
}
#endif
