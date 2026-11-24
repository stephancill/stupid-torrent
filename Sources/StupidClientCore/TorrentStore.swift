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

public struct PlaybackRequest: Identifiable {
    public let id = UUID()
    public let torrent: Torrent
    public let fileIndex: Int
}

struct TorrentRecord: Codable, Equatable {
    var addedAt: Date
    var isPaused = false
    var playbackPositions: [Int: Double] = [:]
}

@MainActor
@Observable
public final class TorrentStore {
    public private(set) var items: [TorrentItem] = []
    public private(set) var resolvingItems: [ResolvingTorrentItem] = []
    public private(set) var restorationComplete = false
    public var addError: String?
    public var pendingPlayback: PlaybackRequest?

    public let downloadsURL: URL
    private let torrentsURL: URL
    private let defaults: UserDefaults
    private static let recordsKey = "torrentRecords"
    private static let playbackMargin = 5.0
    private let dhtEnabled: Bool
    private var records: [String: TorrentRecord]
    private var restoredIDs: Set<String> = []
    private var isRestoring = false
    private var submittedRestoredBackgroundTasks = false

    public convenience init() {
        #if os(tvOS)
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        self.init(documentsURL: directory)
    }

    init(documentsURL: URL, dhtEnabled: Bool = true, defaults: UserDefaults = .standard) {
        downloadsURL = documentsURL.appendingPathComponent("downloads", isDirectory: true)
        torrentsURL = documentsURL.appendingPathComponent("torrents", isDirectory: true)
        self.defaults = defaults
        self.dhtEnabled = dhtEnabled
        records = Self.loadRecords(from: defaults)
        try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: torrentsURL, withIntermediateDirectories: true)
    }

    private static func loadRecords(from defaults: UserDefaults) -> [String: TorrentRecord] {
        guard let data = defaults.data(forKey: recordsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: TorrentRecord].self, from: data)
        } catch {
            TorrentLog.log("discarding unreadable torrent records: \(error.localizedDescription)")
            return [:]
        }
    }

    private func saveRecords() {
        do {
            defaults.set(try JSONEncoder().encode(records), forKey: Self.recordsKey)
        } catch {
            TorrentLog.log("could not save torrent records: \(error.localizedDescription)")
        }
    }

    private func updateRecord(id: String, _ update: (inout TorrentRecord) -> Void) {
        guard var record = records[id] else { return }
        update(&record)
        guard record != records[id] else { return }
        records[id] = record
        saveRecords()
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
                let id = metainfo.infoHash.hexString
                let canonicalURL = torrentFileURL(id: id)
                if url != canonicalURL {
                    renameLegacyTorrentFile(from: url, to: canonicalURL)
                }
                restoredIDs.insert(id)
                try? await add(metainfo: metainfo, persist: false, submitBackgroundTask: false)
            }
            restorationComplete = true
        }
    }

    private func renameLegacyTorrentFile(from url: URL, to canonicalURL: URL) {
        do {
            if FileManager.default.fileExists(atPath: canonicalURL.path) {
                try FileManager.default.removeItem(at: url)
            } else {
                try FileManager.default.moveItem(at: url, to: canonicalURL)
            }
        } catch {
            TorrentLog.log("could not rename \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func submitRestoredBackgroundTasks() {
        guard restorationComplete, !submittedRestoredBackgroundTasks else { return }
        submittedRestoredBackgroundTasks = true
        let restoredItems = items.filter {
            restoredIDs.contains($0.id) && records[$0.id]?.isPaused != true && !$0.isComplete
        }
        Task {
            for item in restoredItems {
                await trackBackgroundDownload(item, submit: true)
            }
        }
    }

    public func item(infoHash: String) -> TorrentItem? {
        items.first { $0.id == infoHash }
    }

    public func isResolving(infoHash: String) -> Bool {
        resolvingItems.contains { $0.id == infoHash }
    }

    public func contains(infoHash: String) -> Bool {
        item(infoHash: infoHash) != nil || isResolving(infoHash: infoHash)
    }

    public var needsNetwork: Bool {
        !resolvingItems.isEmpty || items.contains { $0.status.state == .downloading }
    }

    public func addMagnet(_ string: String) throws {
        let magnet = try MagnetLinkParser.parse(string.trimmingCharacters(in: .whitespacesAndNewlines))
        let id = magnet.infoHash.hexString
        guard !contains(infoHash: id) else { throw TorrentStoreError.alreadyAdded }
        let addedAt = Date.now
        resolvingItems.append(ResolvingTorrentItem(id: id, name: magnet.displayName ?? id, addedAt: addedAt))
        Task {
            do {
                let result = try await MagnetBootstrapper.metainfoAndPeer(from: magnet)
                try await add(
                    metainfo: result.metainfo,
                    persist: true,
                    injectedPeer: result.metadataPeer,
                    addedAt: addedAt
                )
                resolvingItems.removeAll { $0.id == id }
            } catch {
                resolvingItems.removeAll { $0.id == id }
                addError = "Could not resolve magnet: \(error.localizedDescription)"
            }
        }
    }

    public func addFile(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let metainfo = try Metainfo(data: Data(contentsOf: url))
        guard !contains(infoHash: metainfo.infoHash.hexString) else { throw TorrentStoreError.alreadyAdded }
        Task {
            do {
                try await add(metainfo: metainfo, persist: true)
            } catch {
                addError = error.localizedDescription
            }
        }
    }

    private func torrentDirectory(for metainfo: Metainfo) -> URL {
        let name = metainfo.displayName.replacingOccurrences(of: "/", with: "-")
        let prefix = metainfo.infoHash.hexString.prefix(8)
        return downloadsURL.appendingPathComponent("\(name) \(prefix)", isDirectory: true)
    }

    private func torrentFileURL(id: String) -> URL {
        torrentsURL.appendingPathComponent("\(id).torrent")
    }

    func add(
        metainfo: Metainfo,
        persist: Bool,
        injectedPeer: PeerAddress? = nil,
        addedAt: Date = .now,
        submitBackgroundTask: Bool = true
    ) async throws {
        let id = metainfo.infoHash.hexString
        guard item(infoHash: id) == nil else { throw TorrentStoreError.alreadyAdded }
        if persist {
            try metainfo.torrentData().write(to: torrentFileURL(id: id))
        }
        let record = records[id] ?? TorrentRecord(addedAt: addedAt)
        if records[id] == nil {
            records[id] = record
            saveRecords()
        }
        let directory = torrentDirectory(for: metainfo)
        let torrent = Torrent(
            directory: directory,
            metainfo: metainfo,
            enableDHT: dhtEnabled,
            startPaused: record.isPaused
        )
        if let injectedPeer {
            await torrent.addPeer(host: injectedPeer.host, port: injectedPeer.port)
        }
        let item = TorrentItem(torrent: torrent, isPaused: record.isPaused, addedAt: record.addedAt)
        items.append(item)
        item.start()
        await trackBackgroundDownload(
            item,
            submit: submitBackgroundTask && !item.isPaused && !item.isComplete
        )
    }

    public func remove(_ item: TorrentItem) {
        Task { await cancelBackgroundDownload(item) }
        item.stop()
        items.removeAll { $0.id == item.id }
        records[item.id] = nil
        saveRecords()
        try? FileManager.default.removeItem(at: torrentFileURL(id: item.id))
        try? FileManager.default.removeItem(at: torrentDirectory(for: item.metainfo))
    }

    public func togglePause(_ item: TorrentItem) {
        guard !item.isComplete else { return }
        let wasPaused = item.isPaused
        updateRecord(id: item.id) { $0.isPaused = !wasPaused }
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

    public func play(item: TorrentItem, fileIndex: Int) {
        pendingPlayback = PlaybackRequest(torrent: item.torrent, fileIndex: fileIndex)
    }

    public func resumePosition(torrent: Torrent, fileIndex: Int, duration: Double) -> Double? {
        guard let saved = records[torrent.metainfo.infoHash.hexString]?.playbackPositions[fileIndex] else {
            return nil
        }
        let target = duration.isFinite && duration > 0 ? min(saved, duration - Self.playbackMargin) : saved
        return target > Self.playbackMargin ? target : nil
    }

    public func recordPlayhead(seconds: Double, duration: Double, torrent: Torrent, fileIndex: Int) {
        guard seconds.isFinite, seconds > Self.playbackMargin else { return }
        if duration.isFinite, duration > 0, seconds >= duration - Self.playbackMargin { return }
        updateRecord(id: torrent.metainfo.infoHash.hexString) { $0.playbackPositions[fileIndex] = seconds }
    }

    #if DEBUG
    public func firstItem(timeout: Duration = .seconds(60)) async -> TorrentItem? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let first = items.first { return first }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }
    #endif
}
