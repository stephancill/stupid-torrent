import Foundation

private struct BlockKey: Hashable {
    let index: Int
    let begin: Int
}

/// Runs one peer connection: handshake, interest, request pipeline, and message handling.
/// Lifecycle is owned by a caller task; it calls back into the `Torrent` actor for block
/// allocation, block delivery, and seeding reads.
public final class PeerSession: @unchecked Sendable {
    public let id = UUID()
    public let address: PeerAddress

    private let torrent: Torrent
    private let infoHash: Data
    private let peerID: Data
    private let stream: PeerStream
    private let isInitiator: Bool

    private var peerChoked = true
    private var outstanding: Set<BlockKey> = []
    private let maxOutstanding = 48

    public init(torrent: Torrent, address: PeerAddress, infoHash: Data, peerID: Data, stream: PeerStream, isInitiator: Bool) {
        self.torrent = torrent
        self.address = address
        self.infoHash = infoHash
        self.peerID = peerID
        self.stream = stream
        self.isInitiator = isInitiator
    }

    public func run() async {
        do {
            try await performHandshake()
            TorrentLog.log("handshake ok with \(address.host)")
            try await stream.send(PeerMessage.interested.encode())
            try await receiveLoop()
        } catch {
            TorrentLog.log("peer \(address.host) dropped: \(error)")
        }
        stream.close()
        await torrent.peerDisconnected(self)
    }

    /// Closes the underlying stream, causing `run()` to unwind.
    public func disconnect() {
        stream.close()
    }

    private func performHandshake() async throws {
        let local = Handshake.make(extensionEnabled: false, infoHash: infoHash, peerID: peerID)
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
    }

    private func receiveLoop() async throws {
        while true {
            let lengthData = try await stream.read(exactly: 4)
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
            case .have:
                break
            case .bitfield:
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

    private func refillPipeline() async {
        var batch = Data()
        while !peerChoked, outstanding.count < maxOutstanding {
            guard let block = await torrent.nextBlockRequest(for: self) else { break }
            let key = BlockKey(index: block.index, begin: block.begin)
            outstanding.insert(key)
            batch.append(PeerMessage.request(block).encode())
        }
        guard !batch.isEmpty else { return }
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
