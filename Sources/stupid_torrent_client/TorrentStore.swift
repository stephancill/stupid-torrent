import Foundation
import Observation
import TorrentCore

@MainActor
@Observable
final class TorrentStore {
    var items: [TorrentItem] = []
    var isAdding = false
    var addError: String?

    private let documentsURL: URL
    let downloadsURL: URL
    private let torrentsURL: URL
    private let datesURL: URL
    private var addedDates: [String: Date] = [:]

    init() {
        documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadsURL = documentsURL.appendingPathComponent("downloads", isDirectory: true)
        torrentsURL = documentsURL.appendingPathComponent("torrents", isDirectory: true)
        datesURL = documentsURL.appendingPathComponent("added-dates.json")
        addedDates = Self.loadDates(datesURL)
        try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: torrentsURL, withIntermediateDirectories: true)
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
            add(metainfo: metainfo, persist: false)
        }
    }

    func addMagnet(_ string: String) async {
        do {
            let magnet = try MagnetLinkParser.parse(string)
            isAdding = true
            let metainfo = try await MagnetBootstrapper.metainfo(from: magnet)
            add(metainfo: metainfo, persist: true)
        } catch {
            addError = "Could not resolve magnet: \(error)"
        }
        isAdding = false
    }

    func addFile(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let metainfo = try Metainfo(data: data)
            add(metainfo: metainfo, persist: true)
        } catch {
            addError = "Could not read torrent file: \(error)"
        }
    }

    private func add(metainfo: Metainfo, persist: Bool) {
        if persist {
            persistTorrent(metainfo)
        }
        guard !items.contains(where: { $0.id == metainfo.infoHash.hexString }) else { return }
        let key = metainfo.infoHash.hexString
        if addedDates[key] == nil {
            addedDates[key] = .now
            saveDates()
        }
        let torrent = Torrent(directory: downloadsURL, metainfo: metainfo)
        let verifiedCount = Storage.loadVerifiedCount(
            directory: downloadsURL,
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
        let fileName = metainfo.name.replacingOccurrences(of: "/", with: "-") + ".torrent"
        let url = torrentsURL.appendingPathComponent(fileName)
        try? metainfo.torrentData().write(to: url)
    }

    func remove(_ item: TorrentItem) {
        item.stop()
        items.removeAll { $0.id == item.id }
        addedDates.removeValue(forKey: item.id)
        saveDates()
        let url = torrentsURL.appendingPathComponent(item.name.replacingOccurrences(of: "/", with: "-") + ".torrent")
        try? FileManager.default.removeItem(at: url)
    }
}
