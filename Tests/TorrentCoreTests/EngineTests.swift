import Testing
import Foundation
import CryptoKit
import Bencode

@testable import TorrentCore

func syntheticTorrent(pieceLength: Int = 16, pieceCount: Int = 4) throws -> (Metainfo, Data) {
    let pieces = (0..<pieceCount).map { i in
        Data((0..<pieceLength).map { UInt8((i * pieceLength + $0) % 251) })
    }
    let fileData = pieces.reduce(Data(), +)
    let info: [String: BValue] = [
        "name": .string(Data("synth.mkv".utf8)),
        "piece length": .int(pieceLength),
        "length": .int(fileData.count),
        "pieces": .string(pieces.reduce(Data()) { $0 + Data(Insecure.SHA1.hash(data: $1)) }),
    ]
    let metainfo = try Metainfo(infoDict: Bencode.encode(.dictionary(info)), trackers: [])
    return (metainfo, fileData)
}

@Suite struct BlockSchedulerTests {
    private let blockSize = PeerMessage.blockSize
    private let alice = UUID()
    private let bob = UUID()
    private let carol = UUID()
    private let aliceAddress = PeerAddress(host: "10.0.0.1", port: 1)
    private let bobAddress = PeerAddress(host: "10.0.0.2", port: 2)

    private func scheduler(pieceCount: Int = 1) throws -> BlockScheduler {
        let (metainfo, _) = try syntheticTorrent(pieceLength: 2 * PeerMessage.blockSize, pieceCount: pieceCount)
        return BlockScheduler(metainfo: metainfo, verified: Bitfield(count: pieceCount))
    }

    private func requests(_ scheduler: inout BlockScheduler, for peer: UUID, now: ContinuousClock.Instant = .now) -> [Block] {
        var blocks: [Block] = []
        while let block = scheduler.nextRequest(for: peer, has: { _ in true }, now: now) {
            blocks.append(block)
        }
        return blocks
    }

    @Test func missingBlocksAreRequestedRedundantlyUpToTheCap() throws {
        var scheduler = try scheduler()
        #expect(requests(&scheduler, for: alice).map(\.begin) == [0, blockSize])
        #expect(requests(&scheduler, for: bob).map(\.begin) == [0, blockSize])
        #expect(requests(&scheduler, for: carol).isEmpty)

        scheduler.urgentPieces = [0]
        #expect(requests(&scheduler, for: carol).map(\.begin) == [0, blockSize])
        #expect(scheduler.requesters[BlockKey(index: 0, begin: 0)] == [alice, bob, carol])
    }

    @Test func failedPieceBlamesTheAddressesThatSentItsBlocks() throws {
        var scheduler = try scheduler()
        let blocks = requests(&scheduler, for: alice)
        let first = scheduler.receive(blocks[0], byteCount: blockSize, from: alice, address: aliceAddress, now: .now)
        #expect(first == .accepted)
        let duplicate = scheduler.receive(blocks[0], byteCount: blockSize, from: bob, address: bobAddress, now: .now)
        #expect(duplicate == .ignored)
        let last = scheduler.receive(blocks[1], byteCount: blockSize, from: bob, address: bobAddress, now: .now)
        #expect(last == .completed)

        let blamed = scheduler.fail(piece: 0)
        #expect(blamed == [aliceAddress, bobAddress])
        #expect(scheduler.active.isEmpty)
        #expect(scheduler.inFlightCount(for: alice) == 0)
        #expect(requests(&scheduler, for: bob).map(\.begin) == [0, blockSize])
    }

    @Test func repeatedFailuresStopBlamingPeers() throws {
        var scheduler = try scheduler()
        for attempt in 1...BlockScheduler.maxPieceFailures {
            let blocks = requests(&scheduler, for: alice)
            for block in blocks {
                _ = scheduler.receive(block, byteCount: block.length, from: alice, address: aliceAddress, now: .now)
            }
            let blamed = scheduler.fail(piece: 0)
            #expect(blamed.isEmpty == (attempt == BlockScheduler.maxPieceFailures))
        }
    }

    @Test func stalledPieceIsReRequestedFromOtherPeers() throws {
        var scheduler = try scheduler()
        let start = ContinuousClock.now
        _ = requests(&scheduler, for: alice, now: start)
        _ = scheduler.receive(Block(index: 0, begin: 0, length: blockSize), byteCount: blockSize, from: alice, address: aliceAddress, now: start)
        _ = requests(&scheduler, for: bob, now: start)

        let early = scheduler.requeueStalled(now: start + .seconds(5))
        #expect(early.isEmpty)
        let stalled = scheduler.requeueStalled(now: start + BlockScheduler.stallTimeout)
        #expect(stalled == [0])
        #expect(scheduler.requesters.isEmpty)
        #expect(requests(&scheduler, for: alice).isEmpty)
        #expect(requests(&scheduler, for: carol).map(\.begin) == [blockSize])
    }

    @Test func urgentPieceStallsSooner() throws {
        var scheduler = try scheduler()
        let start = ContinuousClock.now
        scheduler.urgentPieces = [0]
        _ = requests(&scheduler, for: alice, now: start)
        let stalled = scheduler.requeueStalled(now: start + BlockScheduler.urgentStallTimeout)
        #expect(stalled == [0])
    }

    @Test func disconnectReleasesThePeersRequests() throws {
        var scheduler = try scheduler()
        _ = requests(&scheduler, for: alice)
        _ = scheduler.receive(Block(index: 0, begin: 0, length: blockSize), byteCount: blockSize, from: alice, address: aliceAddress, now: .now)

        scheduler.release(peer: alice)
        #expect(scheduler.requesters.isEmpty)
        #expect(scheduler.inFlightCount(for: alice) == 0)
        #expect(requests(&scheduler, for: bob).map(\.begin) == [blockSize])
    }

    @Test func completedPieceIsVerifiedAndFreesPipelines() throws {
        var scheduler = try scheduler(pieceCount: 2)
        let blocks = requests(&scheduler, for: alice)
        #expect(blocks.count == 4)
        for block in blocks where block.index == 0 {
            _ = scheduler.receive(block, byteCount: block.length, from: alice, address: aliceAddress, now: .now)
        }
        scheduler.complete(piece: 0)
        #expect(scheduler.picker.verified[0])
        #expect(scheduler.inFlightCount(for: alice) == 2)
        let late = scheduler.receive(blocks[0], byteCount: blockSize, from: bob, address: bobAddress, now: .now)
        #expect(late == .ignored)
    }
}

@Suite struct PeerPoolTests {
    private let address = PeerAddress(host: "10.0.0.9", port: 9)

    @Test func secondStrikeBansAndBlocksRequeueing() {
        var pool = PeerPool(capacity: 2)
        let firstStrike = pool.strike(address)
        #expect(!firstStrike)
        let secondStrike = pool.strike(address)
        #expect(secondStrike)
        pool.enqueue(address, isConnected: false)
        let dial = pool.nextDial(connectedCount: 0)
        #expect(dial == nil)
        let delay = pool.reconnectDelay(for: address, handshook: true)
        #expect(delay == nil)
    }

    @Test func dialsRespectCapacityAndBackOff() {
        var pool = PeerPool(capacity: 1)
        let other = PeerAddress(host: "10.0.0.10", port: 10)
        pool.enqueue(address, isConnected: false)
        pool.enqueue(other, isConnected: false)
        pool.enqueue(address, isConnected: false)
        let firstDial = pool.nextDial(connectedCount: 0)
        #expect(firstDial == address)
        let overCapacity = pool.nextDial(connectedCount: 0)
        #expect(overCapacity == nil)
        pool.dialEnded(address)
        let delay = pool.reconnectDelay(for: address, handshook: false)
        #expect(delay == PeerPool.reconnectBackoff[0])
        let nextDial = pool.nextDial(connectedCount: 0)
        #expect(nextDial == other)
    }
}

@Suite struct SeedingTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitForListenPort(_ torrent: Torrent) async throws -> UInt16 {
        for _ in 0..<100 {
            let port = await torrent.listeningPort
            if port != 0 { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TimeoutError()
    }

    @Test func engineServesVerifiedPiecesToAnotherEngine() async throws {
        let pieceLength = 2 * PeerMessage.blockSize
        let (metainfo, data) = try syntheticTorrent(pieceLength: pieceLength, pieceCount: 4)
        let seederDir = try tempDir()
        let leecherDir = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: seederDir)
            try? FileManager.default.removeItem(at: leecherDir)
        }
        try data.write(to: seederDir.appendingPathComponent("synth.mkv"))
        var sidecar = Data()
        sidecar.appendUInt32BE(UInt32(metainfo.pieceCount))
        sidecar.append(Bitfield(bits: [true, true, false, false]).data())
        try sidecar.write(to: Storage.sidecarURL(directory: seederDir, infoHash: metainfo.infoHash))

        let seeder = Torrent(directory: seederDir, metainfo: metainfo, enableDHT: false)
        let seederRun = Task { await seeder.run() }
        defer { seederRun.cancel() }
        let port = try await waitForListenPort(seeder)

        let leecher = Torrent(directory: leecherDir, metainfo: metainfo, stopAfterBytes: Int64(2 * pieceLength), enableDHT: false)
        await leecher.addPeer(host: "127.0.0.1", port: port)
        let leecherRun = Task { await leecher.run() }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await leecherRun.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished)
        if !finished {
            leecherRun.cancel()
            await leecher.stop()
        }

        let result = try await PieceVerifier.verify(metainfo: metainfo, directory: leecherDir)
        #expect(result.ok == [0, 1])
        var uploaded: Int64 = 0
        for _ in 0..<40 where uploaded < Int64(2 * pieceLength) {
            try await Task.sleep(for: .milliseconds(100))
            uploaded = await seeder.statusBroadcast.value.uploadedBytes
        }
        #expect(uploaded >= Int64(2 * pieceLength))
        await seeder.stop()
    }
}
