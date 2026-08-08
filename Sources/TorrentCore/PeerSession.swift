import Foundation

/// Runs one peer connection: handshake, interest, request pipeline, and message handling.
/// Lifecycle is owned by a caller task; it calls back into the `Torrent` actor for block
/// allocation, block delivery, and seeding reads.
public final class PeerSession: @unchecked Sendable {
    public let id = UUID()
    public let address: PeerAddress

    private let torrent: Torrent
    private let infoHash: Data
    private let peerID: Data
    private let stream: any PeerTransport
    private let isInitiator: Bool
    /// Whether to attempt the MSE/PE (BEP 10) handshake first. TCP uses it; µTP connects plaintext.
    private let supportsMSE: Bool
    /// Set once the BitTorrent handshake completes (used by `Torrent` for µTP-after-TCP fallback).
    public private(set) var completedHandshake = false

    private var peerChoked = true
    private var outstanding: Set<BlockKey> = []
    private let maxOutstanding = 48
    /// A peer that sends nothing for this long while we're connected is considered dead and
    /// disconnected, freeing its pool slot for a live seeder.
    private let peerIdleTimeout = Duration.seconds(30)

    /// The blocks this peer currently has requested and is waiting on. The picker serves distinct
    /// blocks per peer (excluding this set) so a peer fills its whole pipeline with different
    /// blocks instead of stalling on one missing block per round-trip.
    var outstandingKeys: Set<BlockKey> { outstanding }

    /// Which pieces this peer claims to have (from its bitfield/have/have-all messages).
    /// Peers that advertise nothing for this torrent are leechers without data; requesting blocks
    /// from them is wasted round-trips, so the picker only serves peers with a known piece.
    public private(set) var peerPieces: Bitfield?

    public init(torrent: Torrent, address: PeerAddress, infoHash: Data, peerID: Data, stream: any PeerTransport, isInitiator: Bool, supportsMSE: Bool = true, pieceCount: Int) {
        self.torrent = torrent
        self.address = address
        self.infoHash = infoHash
        self.peerID = peerID
        self.stream = stream
        self.isInitiator = isInitiator
        self.supportsMSE = supportsMSE
        self.peerPieces = Bitfield(count: pieceCount)
    }

    public func run(handshakeBudget: Duration? = nil) async {
        do {
            if let budget = handshakeBudget {
                try await runHandshakeWithin(budget: budget)
            } else {
                try await performHandshake()
            }
            TorrentLog.log("handshake ok with \(address.host)")
            try await stream.send(PeerMessage.interested.encode())
            try await receiveLoop()
        } catch {
            TorrentLog.log("peer \(address.host) dropped: \(error)")
        }
        stream.close()
        await torrent.peerDisconnected(self)
    }

    /// Runs the handshake but gives up (closing the stream, which unblocks any in-flight read)
    /// once `budget` elapses without completion — used so a µTP attempt that stalls before the BT
    /// handshake can fall back to TCP.
    private func runHandshakeWithin(budget: Duration) async throws {
        let deadline = ContinuousClock.now + budget
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.performHandshake()
            }
            group.addTask {
                while !self.completedHandshake {
                    if ContinuousClock.now > deadline {
                        self.stream.close()
                        throw PeerStreamError.timeout
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// Closes the underlying stream, causing `run()` to unwind.
    public func disconnect() {
        stream.close()
    }

    /// Whether the peer claims to have `piece`. Peers that never advertised a bitfield/have are
    /// treated as leechers with nothing (the picker won't request from them).
    public func hasPiece(_ piece: Int) -> Bool {
        guard let pieces = peerPieces, piece >= 0, piece < pieces.count else { return false }
        return pieces[piece]
    }

    private func performHandshake() async throws {
        // MSE/PE (BEP 10): obfuscate the handshake + payload. Some peers answer in plaintext
        // (they don't support MSE) — fall back and continue unencrypted. µTP is plaintext.
        if supportsMSE, let stream = stream as? PeerStream {
            let mse = MSEHandshake(stream: stream)
            do {
                if isInitiator {
                    try await mse.performAsInitiator(infoHash: infoHash)
                } else {
                    try await mse.performAsResponder(infoHash: infoHash)
                }
                TorrentLog.log("\(address.host): MSE handshake ok (method \(mse.method == .rc4 ? "rc4" : "plaintext"))")
            } catch MSEError.plaintextFallback {
                TorrentLog.log("\(address.host): peer doesn't support MSE, using plaintext")
            }
        }

        let local = Handshake.make(extensionEnabled: true, infoHash: infoHash, peerID: peerID)
        if isInitiator {
            try await stream.send(local.encode())
            let data = try await stream.read(exactly: Handshake.length)
            let remote = try Handshake.parse(data)
            guard remote.infoHash == infoHash else { throw PeerWireError.wrongInfoHash }
        } else {
            let data = try await stream.read(exactly: Handshake.length)
            let remote = try Handshake.parse(data)
            guard remote.infoHash == infoHash else { throw PeerWireError.wrongInfoHash }
            try await stream.send(local.encode())
        }
        completedHandshake = true
    }

    private func receiveLoop() async throws {
        while true {
            let lengthData = try await readWithTimeout(exactly: 4)
            let length = Int(lengthData.readUInt32BE(at: 0))
            if length == 0 { continue } // keepalive
            let body = try await stream.read(exactly: length)
            let message = try PeerMessage.decode(length: length, body: body)
            switch message {
            case .choke:
                peerChoked = true
                TorrentLog.log("\(address.host) choked us")
            case .unchoke:
                peerChoked = false
                TorrentLog.log("\(address.host) unchoked us")
                await refillPipeline()
            case .interested:
                break
            case .notInterested:
                break
            case .have(let index):
                if peerPieces != nil, index >= 0, index < peerPieces!.count {
                    peerPieces![index] = true
                }
                await refillPipeline()
            case .bitfield(let bits):
                if let pieces = peerPieces {
                    for index in 0..<pieces.count where index < bits.count * 8 && (bits[index / 8] & (0x80 >> (index % 8))) != 0 {
                        peerPieces![index] = true
                    }
                }
                await refillPipeline()
            case .haveAll:
                if let pieces = peerPieces {
                    for index in 0..<pieces.count {
                        peerPieces![index] = true
                    }
                }
                await refillPipeline()
            case .haveNone:
                break
            case .request(let block):
                await serveRequest(block)
            case .piece(let block, let data):
                outstanding.remove(BlockKey(index: block.index, begin: block.begin))
                await torrent.receivedBlock(block, data: data, from: self)
                await refillPipeline()
            case .cancel(let block):
                outstanding.remove(BlockKey(index: block.index, begin: block.begin))
            case .port:
                break
            case .extended:
                break
            }
        }
    }

    /// Reads `count` bytes but gives up (closing the stream) if the peer sends nothing within
    /// `peerIdleTimeout` — a peer that stops delivering data holds a pool slot that a live seeder
    /// could use, so cycle it out.
    private func readWithTimeout(exactly count: Int) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.stream.read(exactly: count)
            }
            group.addTask {
                try? await Task.sleep(for: self.peerIdleTimeout)
                if Task.isCancelled { return Data() }
                self.stream.close()
                throw PeerStreamError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Data()
        }
    }

    private func refillPipeline() async {
        var batch = Data()
        while !peerChoked, outstanding.count < maxOutstanding {
            guard let block = await torrent.nextBlockRequest(for: self) else {
                TorrentLog.log("\(address.host): refill -> no block (picker empty)")
                break
            }
            let key = BlockKey(index: block.index, begin: block.begin)
            // Defensive: `nextBlockRequest` excludes the peer's in-flight blocks, so this only
            // trips if that guarantee ever slips — skip rather than truncating the pipeline.
            guard !outstanding.contains(key) else { continue }
            outstanding.insert(key)
            batch.append(PeerMessage.request(block).encode())
        }
        guard !batch.isEmpty else { return }
        TorrentLog.log("\(address.host): requesting \(outstanding.count) blocks")
        do {
            try await stream.send(batch)
        } catch {
            return
        }
    }

    private func serveRequest(_ block: Block) async {
        guard let data = await torrent.readVerifiedPiece(piece: block.index, offset: block.begin, length: block.length) else { return }
        try? await stream.send(PeerMessage.piece(block, data).encode())
    }
}
