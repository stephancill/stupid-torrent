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
    @Published public private(set) var audioTracks: [Track] = []
    @Published public private(set) var subtitleTracks: [Track] = []

    public struct Track: Identifiable, Equatable {
        public let id: Int
        public let name: String
        public let isSelected: Bool
    }

    private let player = VLCMediaPlayer()
    private let media: VLCMedia
    private let stream: TorrentSeekableInputStream
    private var notificationTokens: [NSObjectProtocol] = []

    public init(torrent: Torrent, fileIndex: Int) {
        let source = TorrentStreamSourceAdapter(torrent: torrent)
        stream = TorrentSeekableInputStream(source: source, fileIndex: fileIndex)
        media = VLCMedia(stream: stream)
        // Prioritize the MKV Cues index at the tail so seeks/timeline work early on a partial file
        // (analogous to the moov-tail handling in TorrentStreamSession). The picker's jump
        // classification promotes it above the sequential cursor.
        let size = torrent.fileSize(fileIndex)
        let tailStart = max(0, size - 2 * 1024 * 1024)
        Task {
            await source.prioritize(fileIndex: fileIndex, range: tailStart..<size)
        }
        player.media = media
        observe()
    }

    public func attach(drawable: UIView) {
        player.drawable = drawable
        player.play()
    }

    public func play() { player.play() }
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
        player.stop()
        stream.close()
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
        switch player.state {
        case .stopped: state = positionMs > 0 && durationMs > 0 && positionMs >= durationMs ? .ended : .idle
        case .opening: state = .opening
        case .buffering: state = .buffering
        case .playing: state = .playing
        case .paused: state = .paused
        case .ended: state = .ended
        case .error: state = .failed
        @unknown default: state = .idle
        }
        isSeekable = player.isSeekable
        refreshTracks()
    }

    private func refreshTime() {
        positionMs = player.time.value?.int64Value ?? 0
        durationMs = media.length.value?.int64Value ?? 0
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
