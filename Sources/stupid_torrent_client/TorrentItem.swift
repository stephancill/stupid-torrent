import Foundation
import Observation
import TorrentCore

@MainActor
@Observable
final class TorrentItem: Identifiable, Hashable {
    nonisolated let id: String
    nonisolated let torrent: Torrent
    nonisolated let metainfo: Metainfo
    nonisolated let addedAt: Date
    var status: TorrentStatus?
    /// Pause flags updated from the status stream only when they actually change, so views like the
    /// detail toolbar menu can read them without re-rendering on every 1s status tick.
    var isPaused = false
    var canPause = false

    private var statusTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    init(torrent: Torrent, initialVerifiedCount: Int = 0, addedAt: Date = .now) {
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

    nonisolated var name: String { metainfo.displayName }

    var isComplete: Bool { status?.isComplete ?? false }

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
        Task { await torrent.stop() }
        statusTask = nil
        runTask = nil
    }

    /// Pauses or resumes the download. The status/run tasks stay alive across both — `pause()`
    /// tears down the engine's network while `run()` parks, and `resume()` restarts it.
    func togglePause() {
        guard !isComplete else { return }
        if isPaused {
            Task { await torrent.resume() }
        } else {
            Task { await torrent.pause() }
        }
    }

    nonisolated static func == (lhs: TorrentItem, rhs: TorrentItem) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
