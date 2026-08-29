import Foundation
import Observation
import TorrentCore

private enum TorrentStoreError: LocalizedError {
    case alreadyAdded

    var errorDescription: String? {
        "This torrent has already been added."
    }
}

public struct ResolvingTorrentItem: Identifiable {
    public let id: String
    public let name: String
    public let addedAt: Date
}

/// A request to open a player for a torrent file. Held on `TorrentStore` (not the detail view,
/// which is recreated on every status tick for a downloading torrent) so the full-screen player
/// cover presented from `ContentView` reliably sees the request.
public struct PlaybackRequest: Identifiable {
    public let id = UUID()
    public let torrent: Torrent
    public let fileIndex: Int
    public let kind: Torrent.PlaybackKind

    public init(torrent: Torrent, fileIndex: Int, kind: Torrent.PlaybackKind) {
        self.torrent = torrent
        self.fileIndex = fileIndex
        self.kind = kind
    }
}

@MainActor
@Observable
public final class TorrentStore {
    public var items: [TorrentItem] = []
    public var resolvingItems: [ResolvingTorrentItem] = []
    public var addError: String?
    public var pendingPlayback: PlaybackRequest?
    public var restorationComplete = false

    private let documentsURL: URL
    public let downloadsURL: URL
    private let torrentsURL: URL
    private let defaults: UserDefaults
    private static let addedDatesKey = "addedDates"
    private static let pausedIDsKey = "pausedIDs"
    private static let playbackPositionsKey = "playbackPositions"
    private let dhtEnabled: Bool
    private var addedDates: [String: Date] = [:]
    private var pausedIDs: Set<String> = []
    /// Cached playback positions keyed by `"<infoHash>|<fileIndex>"`, so each torrent file's
    /// playback can resume where the user left off.
    private var playbackPositions: [String: Double] = [:]
    private var restoredIDs: Set<String> = []
    private var isRestoring = false
    private var submittedRestoredBackgroundTasks = false

    public convenience init() {
        self.init(documentsURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    /// Test seam: point the store at a temporary documents directory and (optionally) disable
    /// the DHT so restore/add stays hermetic.
    init(documentsURL: URL, dhtEnabled: Bool = true, defaults: UserDefaults = .standard) {
        self.documentsURL = documentsURL
        downloadsURL = documentsURL.appendingPathComponent("downloads", isDirectory: true)
        torrentsURL = documentsURL.appendingPathComponent("torrents", isDirectory: true)
        self.defaults = defaults
        self.dhtEnabled = dhtEnabled
        addedDates = defaults.dictionary(forKey: Self.addedDatesKey) as? [String: Date] ?? [:]
        pausedIDs = Set(defaults.array(forKey: Self.pausedIDsKey) as? [String] ?? [])
        playbackPositions = defaults.dictionary(forKey: Self.playbackPositionsKey) as? [String: Double] ?? [:]
        try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: torrentsURL, withIntermediateDirectories: true)
    }

    private func savePausedIDs() {
        defaults.set(Array(pausedIDs), forKey: Self.pausedIDsKey)
    }

    private func savePlaybackPositions() {
        defaults.set(playbackPositions, forKey: Self.playbackPositionsKey)
    }

    private func saveDates() {
        defaults.set(addedDates, forKey: Self.addedDatesKey)
    }

    public func restore() {
        guard items.isEmpty, !isRestoring else { return }
        isRestoring = true
        let files = (try? FileManager.default.contentsOfDirectory(atPath: torrentsURL.path)) ?? []
        Task {
            for name in files where name.hasSuffix(".torrent") {
                let url = torrentsURL.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let metainfo = try? Metainfo(data: data) else { continue }
                restoredIDs.insert(metainfo.infoHash.hexString)
                try? await add(metainfo: metainfo, persist: false, submitBackgroundTask: false)
            }
            restorationComplete = true
        }
    }

    public func submitRestoredBackgroundTasks() {
        guard restorationComplete, !submittedRestoredBackgroundTasks else { return }
        submittedRestoredBackgroundTasks = true
        let restoredItems = items.filter {
            restoredIDs.contains($0.id) && !pausedIDs.contains($0.id) && !$0.isComplete
        }
        Task {
            for item in restoredItems {
                await trackBackgroundDownload(item, submit: true)
            }
        }
    }

    public func addMagnet(_ string: String) throws {
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

    public func addFile(_ url: URL) throws {
        let data = try Self.readScopedData(from: url)
        let metainfo = try Metainfo(data: data)
        Task { try? await add(metainfo: metainfo, persist: true) }
    }

    /// Awaitable file import (test seam; the UI path is fire-and-forget `addFile`).
    public func addFileAndWait(_ url: URL) async throws {
        let data = try Self.readScopedData(from: url)
        let metainfo = try Metainfo(data: data)
        try await add(metainfo: metainfo, persist: true)
    }

    private static func readScopedData(from url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return try Data(contentsOf: url)
    }

    /// The per-torrent data directory under `downloads/`. Named `<display name> <hash-prefix>` so
    /// each torrent owns a unique folder (files and the resume sidecar live inside it) and
    /// same-named torrents cannot collide.
    private func torrentDirectory(for metainfo: Metainfo) -> URL {
        let name = metainfo.displayName.replacingOccurrences(of: "/", with: "-")
        let prefix = metainfo.infoHash.hexString.prefix(8)
        return downloadsURL.appendingPathComponent("\(name) \(prefix)", isDirectory: true)
    }

    private func add(
        metainfo: Metainfo,
        persist: Bool,
        injectedPeer: PeerAddress? = nil,
        submitBackgroundTask: Bool = true
    ) async throws {
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
        let torrent = Torrent(
            directory: directory,
            metainfo: metainfo,
            enableDHT: dhtEnabled,
            startPaused: pausedIDs.contains(key)
        )
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
        await trackBackgroundDownload(
            item,
            submit: submitBackgroundTask && !item.isPaused && !item.isComplete
        )
    }

    private func persistTorrent(_ metainfo: Metainfo) {
        let fileName = metainfo.displayName.replacingOccurrences(of: "/", with: "-") + ".torrent"
        let url = torrentsURL.appendingPathComponent(fileName)
        try? metainfo.torrentData().write(to: url)
    }

    public func remove(_ item: TorrentItem) {
        Task { await cancelBackgroundDownload(item) }
        item.stop()
        items.removeAll { $0.id == item.id }
        addedDates.removeValue(forKey: item.id)
        saveDates()
        pausedIDs.remove(item.id)
        savePausedIDs()
        playbackPositions = playbackPositions.filter { !$0.key.hasPrefix("\(item.id)|") }
        savePlaybackPositions()
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
                // Delete EVERY persisted copy, not just the first: the same torrent can be
                // persisted under several display-name files (a file import names it by its
                // internal `name`, a magnet by its `dn`), and any copy left behind makes
                // restore() re-add the torrent on the next launch.
                try? FileManager.default.removeItem(at: url)
            }
        }
        // Also remove the per-torrent data directory (files + resume sidecar live inside it) so
        // nothing is orphaned.
        try? FileManager.default.removeItem(at: torrentDirectory(for: item.metainfo))
    }

    /// Pauses/resumes a torrent and persists the paused state so it survives a relaunch.
    public func togglePause(_ item: TorrentItem) {
        guard !item.isComplete else { return }
        let wasPaused = item.isPaused
        if wasPaused {
            pausedIDs.remove(item.id)
        } else {
            pausedIDs.insert(item.id)
        }
        savePausedIDs()
        Task {
            if wasPaused {
                await item.torrent.resume()
                await trackBackgroundDownload(item, submit: true)
            } else {
                await cancelBackgroundDownload(item)
                await item.torrent.pause()
            }
        }
    }

    private func trackBackgroundDownload(_ item: TorrentItem, submit: Bool) async {
        #if os(iOS)
        await ContinuedDownloadManager.shared.track(torrent: item.torrent, submit: submit)
        #endif
    }

    private func cancelBackgroundDownload(_ item: TorrentItem) async {
        #if os(iOS)
        await ContinuedDownloadManager.shared.cancel(torrent: item.torrent)
        #endif
    }

    /// The cached playback position (seconds) for a torrent file, or `nil` if none was saved.
    /// Used to resume playback where the user last left off.
    public func playbackPosition(torrent: Torrent, fileIndex: Int) -> Double? {
        playbackPositions[Self.playbackKey(torrent: torrent, fileIndex: fileIndex)]
    }

    /// Persists a file's playback position (seconds) so a later open can resume there.
    public func savePlaybackPosition(_ seconds: Double, torrent: Torrent, fileIndex: Int) {
        playbackPositions[Self.playbackKey(torrent: torrent, fileIndex: fileIndex)] = seconds
        savePlaybackPositions()
    }

    private static func playbackKey(torrent: Torrent, fileIndex: Int) -> String {
        "\(torrent.metainfo.infoHash.hexString)|\(fileIndex)"
    }
}
