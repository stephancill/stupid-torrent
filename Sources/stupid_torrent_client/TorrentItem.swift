import Foundation
import Observation
import TorrentCore

@MainActor
@Observable
final class TorrentItem: Identifiable, Hashable {
    nonisolated let id: String
    nonisolated let torrent: Torrent
    nonisolated let metainfo: Metainfo
    var status: TorrentStatus?

    private var statusTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    init(torrent: Torrent) {
        self.torrent = torrent
        self.metainfo = torrent.metainfo
        self.id = torrent.metainfo.infoHash.hexString
    }

    nonisolated var name: String { metainfo.name }

    func start() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await self.torrent.statusBroadcast.subscribe() {
                self.status = snapshot
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

    func pauseResume() {
        if runTask != nil {
            stop()
        } else {
            start()
        }
    }

    nonisolated static func == (lhs: TorrentItem, rhs: TorrentItem) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
