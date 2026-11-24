import Foundation
import Observation
import Streaming
import TorrentCore

@MainActor
@Observable
public final class TorrentItem: Identifiable, Hashable {
    public nonisolated let id: String
    public nonisolated let torrent: Torrent
    public nonisolated let addedAt: Date
    public nonisolated let fileIndicesBySize: [Int]
    public private(set) var status: TorrentStatus
    public private(set) var isPaused: Bool
    public private(set) var isComplete: Bool

    private var statusTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var playbackAvailability: [Int: Bool] = [:]
    private var playbackAvailabilityTasks: [Int: Task<Void, Never>] = [:]

    init(torrent: Torrent, initialVerifiedCount: Int, isPaused: Bool, addedAt: Date) {
        let metainfo = torrent.metainfo
        self.torrent = torrent
        id = metainfo.infoHash.hexString
        self.addedAt = addedAt
        fileIndicesBySize = metainfo.files.indices.sorted {
            metainfo.files[$0].length > metainfo.files[$1].length
        }
        let status = TorrentStatus(
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
        self.status = status
        self.isPaused = isPaused
        isComplete = status.isComplete
    }

    public nonisolated var metainfo: Metainfo { torrent.metainfo }

    public nonisolated var name: String { metainfo.displayName }

    public func isPlaybackAvailable(fileIndex: Int) -> Bool {
        let name = metainfo.files[fileIndex].name
        guard Torrent.isPlayable(fileNamed: name) else { return false }
        guard Self.needsAvailabilityProbe(fileNamed: name) else { return true }
        return isComplete || playbackAvailability[fileIndex] == true
    }

    public func preparePlaybackAvailability(fileIndex: Int) {
        guard metainfo.files.indices.contains(fileIndex), !isComplete,
              playbackAvailability[fileIndex] == nil,
              playbackAvailabilityTasks[fileIndex] == nil,
              Self.needsAvailabilityProbe(fileNamed: metainfo.files[fileIndex].name) else { return }
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

    private static func needsAvailabilityProbe(fileNamed name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "mkv" || ext == "mka"
    }

    func start() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await self.torrent.statusBroadcast.subscribe() {
                self.status = snapshot
                let paused = snapshot.state == .paused
                if paused != self.isPaused { self.isPaused = paused }
                if snapshot.isComplete != self.isComplete { self.isComplete = snapshot.isComplete }
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
