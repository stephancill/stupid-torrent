import Foundation
import Testing
import TorrentCore
import TorrentTestingSupport
@testable import StupidClientCore

@MainActor
struct TorrentStorePersistenceTests {
    private func makeDocuments() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("torrent-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "torrent-store-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func torrentsDirectory(in documents: URL) -> URL {
        documents.appendingPathComponent("torrents", isDirectory: true)
    }

    private func trackerlessMetainfo() throws -> Metainfo {
        let base = try Metainfo(data: Fixtures.bigBuckBunnyTorrentData)
        return try Metainfo(infoDict: base.infoDict, trackers: [])
    }

    private func restoredStore(documents: URL, defaults: UserDefaults) async -> TorrentStore {
        let store = TorrentStore(documentsURL: documents, dhtEnabled: false, defaults: defaults)
        store.restore()
        var attempts = 0
        while !store.restorationComplete, attempts < 1000 {
            try? await Task.sleep(for: .milliseconds(5))
            attempts += 1
        }
        #expect(store.restorationComplete)
        return store
    }

    @Test func persistsTorrentFileByInfoHash() async throws {
        let documents = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let metainfo = try trackerlessMetainfo()
        let store = TorrentStore(documentsURL: documents, dhtEnabled: false, defaults: defaults)
        try await store.add(metainfo: metainfo, persist: true)

        let files = try FileManager.default.contentsOfDirectory(atPath: torrentsDirectory(in: documents).path)
        #expect(files == ["\(metainfo.infoHash.hexString).torrent"])
        store.remove(store.items[0])
    }

    @Test func recordsPersistAcrossRelaunch() async throws {
        let documents = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let metainfo = try trackerlessMetainfo()
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TorrentStore(documentsURL: documents, dhtEnabled: false, defaults: defaults)
        try await store.add(metainfo: metainfo, persist: true, addedAt: addedAt)
        let item = store.items[0]
        #expect(store.resumePosition(torrent: item.torrent, fileIndex: 0, duration: 600) == nil)

        store.recordPlayhead(seconds: 123.75, duration: 600, torrent: item.torrent, fileIndex: 0)
        store.recordPlayhead(seconds: 3, duration: 600, torrent: item.torrent, fileIndex: 1)
        store.recordPlayhead(seconds: 598, duration: 600, torrent: item.torrent, fileIndex: 2)
        store.togglePause(item)
        item.stop()

        let relaunched = await restoredStore(documents: documents, defaults: defaults)
        let restored = try #require(relaunched.items.first)
        #expect(restored.addedAt == addedAt)
        #expect(restored.isPaused)
        #expect(relaunched.resumePosition(torrent: restored.torrent, fileIndex: 0, duration: 600) == 123.75)
        #expect(relaunched.resumePosition(torrent: restored.torrent, fileIndex: 0, duration: 100) == 95)
        #expect(relaunched.resumePosition(torrent: restored.torrent, fileIndex: 1, duration: 600) == nil)
        #expect(relaunched.resumePosition(torrent: restored.torrent, fileIndex: 2, duration: 600) == nil)
        relaunched.remove(restored)
    }

    @Test func deletedTorrentStaysDeletedAcrossRelaunch() async throws {
        let documents = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TorrentStore(documentsURL: documents, dhtEnabled: false, defaults: defaults)
        try await store.add(metainfo: try trackerlessMetainfo(), persist: true)
        #expect(store.items.count == 1)

        store.remove(store.items[0])
        #expect(store.items.isEmpty)

        let relaunched = await restoredStore(documents: documents, defaults: defaults)
        #expect(relaunched.items.isEmpty)
    }

    @Test func restoreRenamesLegacyTorrentFilesSoRemoveDeletesThem() async throws {
        let documents = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let metainfo = try trackerlessMetainfo()
        let torrents = torrentsDirectory(in: documents)
        try FileManager.default.createDirectory(at: torrents, withIntermediateDirectories: true)
        try metainfo.torrentData().write(to: torrents.appendingPathComponent("Big Buck Bunny A.torrent"))
        try metainfo.torrentData().write(to: torrents.appendingPathComponent("Big Buck Bunny B.torrent"))

        let store = await restoredStore(documents: documents, defaults: defaults)
        #expect(store.items.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: torrents.path) == ["\(metainfo.infoHash.hexString).torrent"])

        store.remove(store.items[0])
        #expect(try FileManager.default.contentsOfDirectory(atPath: torrents.path).isEmpty)

        let relaunched = await restoredStore(documents: documents, defaults: defaults)
        #expect(relaunched.items.isEmpty)
    }
}
