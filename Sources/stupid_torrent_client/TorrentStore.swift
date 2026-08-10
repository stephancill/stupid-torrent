import Foundation
import Observation
import TorrentCore

private enum TorrentStoreError: LocalizedError {
    case alreadyAdded

    var errorDescription: String? {
        "This torrent has already been added."
    }
}

struct ResolvingTorrentItem: Identifiable {
    let id: String
    let name: String
    let addedAt: Date
}

/// A request to open a player for a torrent file. Held on `TorrentStore` (not the detail view,
/// which is recreated on every status tick for a downloading torrent) so the full-screen player
/// cover presented from `ContentView` reliably sees the request.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let torrent: Torrent
    let fileIndex: Int
    let kind: Torrent.PlaybackKind
}

@MainActor
@Observable
final class TorrentStore {
    var items: [TorrentItem] = []
    var resolvingItems: [ResolvingTorrentItem] = []
    var addError: String?
    var pendingPlayback: PlaybackRequest?

    private let documentsURL: URL
    let downloadsURL: URL
    private let torrentsURL: URL
    private let datesURL: URL
    private let pausedURL: URL
    private var addedDates: [String: Date] = [:]
    private var pausedIDs: Set<String> = []

    init() {
        documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadsURL = documentsURL.appendingPathComponent("downloads", isDirectory: true)
        torrentsURL = documentsURL.appendingPathComponent("torrents", isDirectory: true)
        datesURL = documentsURL.appendingPathComponent("added-dates.json")
        pausedURL = documentsURL.appendingPathComponent("paused.json")
        addedDates = Self.loadDates(datesURL)
        pausedIDs = Set(Self.loadPausedIDs(pausedURL))
        try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: torrentsURL, withIntermediateDirectories: true)
    }

    private static func loadPausedIDs(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return raw
    }

    private func savePausedIDs() {
        let raw = Array(pausedIDs).sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return }
        try? data.write(to: pausedURL)
    }

    private static func loadDates(_ url: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        let iso = ISO8601DateFormatter()
        return raw.compactMapValues { iso.date(from: $0) }
    }

    private func saveDates() {
        let iso = ISO8601DateFormatter()
        let raw = addedDates.mapValues { iso.string(from: $0) }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else { return }
        try? data.write(to: datesURL)
    }

    func restore() {
        guard items.isEmpty else { return }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: torrentsURL.path)) ?? []
        for name in files where name.hasSuffix(".torrent") {
            let url = torrentsURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let metainfo = try? Metainfo(data: data) else { continue }
            Task { try? await add(metainfo: metainfo, persist: false) }
        }
    }

    func addMagnet(_ string: String) throws {
        let magnet = try MagnetLinkParser.parse(string.trimmingCharacters(in: .whitespacesAndNewlines))
        let id = magnet.infoHash.hexString
        if items.contains(where: { $0.id == id }) || resolvingItems.contains(where: { $0.id == id }) {
            throw TorrentStoreError.alreadyAdded
        }
        resolvingItems.append(ResolvingTorrentItem(
            id: id,
            name: magnet.displayName ?? id,
            addedAt: .now
        ))
        Task {
            do {
                let result = try await MagnetBootstrapper.metainfoAndPeer(from: magnet)
                let metainfo = result.metainfo
                if let addedAt = resolvingItems.first(where: { $0.id == id })?.addedAt {
                    addedDates[id] = addedAt
                    saveDates()
                }
                try await add(metainfo: metainfo, persist: true, injectedPeer: result.metadataPeer)
                resolvingItems.removeAll { $0.id == id }
            } catch {
                resolvingItems.removeAll { $0.id == id }
                addError = "Could not resolve magnet: \(error)"
            }
        }
    }

    func addFile(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        let metainfo = try Metainfo(data: data)
        Task { try? await add(metainfo: metainfo, persist: true) }
    }

    /// The per-torrent data directory under `downloads/`. Named `<display name> <hash-prefix>` so
    /// each torrent owns a unique folder (files and the resume sidecar live inside it) and
    /// same-named torrents cannot collide.
    private func torrentDirectory(for metainfo: Metainfo) -> URL {
        let name = metainfo.displayName.replacingOccurrences(of: "/", with: "-")
        let prefix = metainfo.infoHash.hexString.prefix(8)
        return downloadsURL.appendingPathComponent("\(name) \(prefix)", isDirectory: true)
    }

    private func add(metainfo: Metainfo, persist: Bool, injectedPeer: PeerAddress? = nil) async throws {
        guard !items.contains(where: { $0.id == metainfo.infoHash.hexString }) else {
            throw TorrentStoreError.alreadyAdded
        }
        if persist {
            persistTorrent(metainfo)
        }
        let key = metainfo.infoHash.hexString
        if addedDates[key] == nil {
            addedDates[key] = .now
            saveDates()
        }
        let directory = torrentDirectory(for: metainfo)
        let torrent = Torrent(directory: directory, metainfo: metainfo, startPaused: pausedIDs.contains(key))
        if let injectedPeer {
            // The metadata-serving peer is a verified-reachable seeder; feed it straight into the
            // download instead of re-discovering the (mostly-dead) swarm.
            await torrent.addPeer(host: injectedPeer.host, port: injectedPeer.port)
        }
        let verifiedCount = Storage.loadVerifiedCount(
            directory: directory,
            infoHash: metainfo.infoHash,
            pieceCount: metainfo.pieceCount
        )
        let item = TorrentItem(
            torrent: torrent,
            initialVerifiedCount: verifiedCount,
            addedAt: addedDates[key] ?? .now
        )
        items.append(item)
        item.start()
    }

    private func persistTorrent(_ metainfo: Metainfo) {
        let fileName = metainfo.displayName.replacingOccurrences(of: "/", with: "-") + ".torrent"
        let url = torrentsURL.appendingPathComponent(fileName)
        try? metainfo.torrentData().write(to: url)
    }

    func remove(_ item: TorrentItem) {
        item.stop()
        items.removeAll { $0.id == item.id }
        addedDates.removeValue(forKey: item.id)
        saveDates()
        pausedIDs.remove(item.id)
        savePausedIDs()
        // Delete the persisted .torrent by matching its info hash, not by reconstructing the
        // filename from displayName: a magnet-resolved torrent's displayName (the `dn` param, e.g.
        // "...x264[eztv.re][eztvx.to]") can differ from the filename it was saved under (e.g.
        // "...x264[eztv.re].torrent"), so a name-based delete silently misses the file and the
        // torrent is re-added by restore() on the next launch.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: torrentsURL.path) {
            for name in files where name.hasSuffix(".torrent") {
                let url = torrentsURL.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let metainfo = try? Metainfo(data: data),
                      metainfo.infoHash.hexString == item.id else { continue }
                try? FileManager.default.removeItem(at: url)
                break
            }
        }
        // Also remove the per-torrent data directory (files + resume sidecar live inside it) so
        // nothing is orphaned.
        try? FileManager.default.removeItem(at: torrentDirectory(for: item.metainfo))
    }

    /// Pauses/resumes a torrent and persists the paused state so it survives a relaunch.
    func togglePause(_ item: TorrentItem) {
        let wasPaused = item.isPaused
        item.togglePause()
        if wasPaused {
            pausedIDs.remove(item.id)
        } else {
            pausedIDs.insert(item.id)
        }
        savePausedIDs()
    }
}
