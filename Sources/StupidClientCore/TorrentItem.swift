import Foundation
import Observation
import Streaming
import TorrentCore

@MainActor
@Observable
public final class TorrentItem: Identifiable, Hashable {
    public nonisolated let id: String
    public nonisolated let torrent: Torrent
    public nonisolated let metainfo: Metainfo
    public nonisolated let addedAt: Date
    public var status: TorrentStatus?
    /// Pause flags updated from the status stream only when they actually change, so views like the
    /// detail toolbar menu can read them without re-rendering on every 1s status tick.
    public var isPaused = false
    public var canPause = false

    private var statusTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var playbackAvailability: [Int: Bool] = [:]
    private var playbackAvailabilityTasks: [Int: Task<Void, Never>] = [:]

    public init(torrent: Torrent, initialVerifiedCount: Int = 0, addedAt: Date = .now) {
        self.torrent = torrent
        self.metainfo = torrent.metainfo
        self.id = torrent.metainfo.infoHash.hexString
        self.addedAt = addedAt
        if metainfo.pieceCount > 0 {
            status = TorrentStatus(
                name: metainfo.displayName,
                infoHash: metainfo.infoHash,
                state: initialVerifiedCount == metainfo.pieceCount ? .seeding : .downloading,
                verifiedCount: initialVerifiedCount,
                pieceCount: metainfo.pieceCount,
                peers: 0,
                seeds: 0,
                downloadRate: 0,
                uploadRate: 0,
                downloadedBytes: 0,
                uploadedBytes: 0
            )
        }
    }

    public nonisolated var name: String { metainfo.displayName }

    public var isComplete: Bool { status?.isComplete ?? false }

    public func isPlaybackAvailable(fileIndex: Int) -> Bool {
        let kind = Torrent.playbackKind(forFileNamed: metainfo.files[fileIndex].name)
        guard kind != .none else { return false }
        let ext = (metainfo.files[fileIndex].name as NSString).pathExtension.lowercased()
        guard ext == "mkv" || ext == "mka" else { return true }
        return isComplete || playbackAvailability[fileIndex] == true
    }

    public func preparePlaybackAvailability(fileIndex: Int) {
        guard metainfo.files.indices.contains(fileIndex), !isComplete,
              playbackAvailability[fileIndex] == nil,
              playbackAvailabilityTasks[fileIndex] == nil else { return }
        let ext = (metainfo.files[fileIndex].name as NSString).pathExtension.lowercased()
        guard ext == "mkv" || ext == "mka" else { return }
        playbackAvailabilityTasks[fileIndex] = Task { [weak self, torrent] in
            let available = await TorrentStreamSession.isPlaybackAvailable(
                torrent: torrent,
                fileIndex: fileIndex
            )
            guard !Task.isCancelled, let self else { return }
            playbackAvailability[fileIndex] = available
            playbackAvailabilityTasks[fileIndex] = nil
        }
    }

    func start() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await self.torrent.statusBroadcast.subscribe() {
                self.status = snapshot
                let newPaused = snapshot.state == .paused
                let newCanPause = !snapshot.isComplete
                if newPaused != self.isPaused { self.isPaused = newPaused }
                if newCanPause != self.canPause { self.canPause = newCanPause }
            }
        }
        runTask = Task {
            await torrent.run()
        }
    }

    func stop() {
        runTask?.cancel()
        statusTask?.cancel()
        playbackAvailabilityTasks.values.forEach { $0.cancel() }
        playbackAvailabilityTasks.removeAll()
        Task { await torrent.stop() }
        statusTask = nil
        runTask = nil
    }

    public nonisolated static func == (lhs: TorrentItem, rhs: TorrentItem) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
