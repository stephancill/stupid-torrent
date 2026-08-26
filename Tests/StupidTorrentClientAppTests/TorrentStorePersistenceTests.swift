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

    private func writePersistedTorrent(
        _ metainfo: Metainfo,
        in documentsURL: URL,
        as name: String
    ) throws {
        let dir = documentsURL.appendingPathComponent("torrents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try metainfo.torrentData().write(to: dir.appendingPathComponent(name))
    }

    /// BBB without trackers so restore/add never touches the network in tests.
    private func trackerlessMetainfo() throws -> Metainfo {
        let base = try Metainfo(data: Fixtures.bigBuckBunnyTorrentData)
        return try Metainfo(infoDict: base.infoDict, trackers: [])
    }

    private func waitForRestoration(_ store: TorrentStore) async {
        var attempts = 0
        while !store.restorationComplete, attempts < 1000 {
            try? await Task.sleep(for: .milliseconds(5))
            attempts += 1
        }
        #expect(store.restorationComplete)
    }

    @Test func deletedTorrentStaysDeletedAcrossRelaunch() async throws {
        let documents = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }

        let metainfo = try trackerlessMetainfo()
        let importURL = documents.appendingPathComponent("import.torrent")
        try metainfo.torrentData().write(to: importURL)

        let store = TorrentStore(documentsURL: documents, dhtEnabled: false)
        try await store.addFileAndWait(importURL)
        #expect(store.items.count == 1)
        #expect(store.restorationComplete == false) // not restored yet — added live

        store.remove(store.items[0])
        #expect(store.items.isEmpty)

        // Relaunch: a fresh store over the same documents directory must find nothing.
        let relaunched = TorrentStore(documentsURL: documents, dhtEnabled: false)
        relaunched.restore()
        await waitForRestoration(relaunched)
        #expect(relaunched.items.isEmpty)
    }

    @Test func removeDeletesEveryPersistedCopyOfTheTorrent() async throws {
        let documents = try makeDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }

        let metainfo = try trackerlessMetainfo()
        // The same torrent persisted under two display names (a file import names it by its
        // internal `name`, a magnet by its `dn`). Deleting only one copy leaves the other for
        // restore() to re-add on every relaunch.
        try writePersistedTorrent(metainfo, in: documents, as: "Big Buck Bunny A.torrent")
        try writePersistedTorrent(metainfo, in: documents, as: "Big Buck Bunny B.torrent")

        let store = TorrentStore(documentsURL: documents, dhtEnabled: false)
        store.restore()
        await waitForRestoration(store)
        #expect(store.items.count == 1) // duplicate copies collapse into a single item

        store.remove(store.items[0])

        let torrentsDir = documents.appendingPathComponent("torrents", isDirectory: true)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: torrentsDir.path)
        #expect(remaining.isEmpty)

        let relaunched = TorrentStore(documentsURL: documents, dhtEnabled: false)
        relaunched.restore()
        await waitForRestoration(relaunched)
        #expect(relaunched.items.isEmpty)
    }
}