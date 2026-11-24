import Foundation

struct BlockScheduler {
    struct ActivePiece {
        var received: Set<Int> = []
        var receivedBytes = 0
        var cursor = 0
        var lastProgress: ContinuousClock.Instant
        var contributors: Set<PeerAddress> = []
        var verifying = false
    }

    enum Delivery: Equatable {
        case ignored
        case accepted
        case completed
    }

    static let maxRedundancy = 2
    static let maxUrgentRedundancy = 4
    static let maxPieceFailures = 5
    static let stallTimeout = Duration.seconds(20)
    static let urgentStallTimeout = Duration.seconds(3)

    let metainfo: Metainfo
    var picker: PiecePicker
    var urgentPieces: Set<Int> = []
    private(set) var active: [Int: ActivePiece] = [:]
    private(set) var requesters: [BlockKey: Set<UUID>] = [:]
    private(set) var inFlight: [UUID: Set<BlockKey>] = [:]
    private(set) var failures: [Int: Int] = [:]

    init(metainfo: Metainfo, verified: Bitfield) {
        self.metainfo = metainfo
        picker = PiecePicker(verified: verified)
    }

    func inFlightCount(for peer: UUID) -> Int {
        inFlight[peer]?.count ?? 0
    }

    mutating func nextRequest(for peer: UUID, has: (Int) -> Bool, now: ContinuousClock.Instant) -> Block? {
        let excluded = inFlight[peer] ?? []
        for piece in active.keys.sorted() where has(piece) {
            if let block = nextBlock(in: piece, excluding: excluded) {
                return register(block, for: peer)
            }
        }
        guard let piece = picker.nextPiece(available: has) else { return nil }
        picker.markRequested(piece)
        if active[piece] == nil {
            active[piece] = ActivePiece(lastProgress: now)
        }
        return nextBlock(in: piece, excluding: excluded).map { register($0, for: peer) }
    }

    mutating func receive(_ block: Block, byteCount: Int, from peer: UUID, address: PeerAddress, now: ContinuousClock.Instant) -> Delivery {
        let key = BlockKey(index: block.index, begin: block.begin)
        inFlight[peer]?.remove(key)
        removeRequester(peer, of: key)
        guard var piece = active[block.index], !piece.verifying, piece.received.insert(block.begin).inserted else {
            return .ignored
        }
        piece.receivedBytes += byteCount
        piece.lastProgress = now
        piece.contributors.insert(address)
        piece.verifying = piece.receivedBytes >= metainfo.length(ofPiece: block.index)
        active[block.index] = piece
        return piece.verifying ? .completed : .accepted
    }

    mutating func complete(piece: Int) {
        picker.markVerified(piece)
        urgentPieces.remove(piece)
        failures.removeValue(forKey: piece)
        deactivate(piece)
    }

    mutating func fail(piece: Int) -> Set<PeerAddress> {
        let count = (failures[piece] ?? 0) + 1
        failures[piece] = count
        let contributors = active[piece]?.contributors ?? []
        requeue(piece: piece)
        return count < Self.maxPieceFailures ? contributors : []
    }

    mutating func requeue(piece: Int) {
        picker.clearRequested(piece)
        deactivate(piece)
    }

    mutating func unverify(piece: Int) {
        picker.verified[piece] = false
        requeue(piece: piece)
    }

    mutating func release(peer: UUID) {
        for key in inFlight.removeValue(forKey: peer) ?? [] {
            removeRequester(peer, of: key)
            if let cursor = active[key.index]?.cursor, key.begin < cursor {
                active[key.index]?.cursor = key.begin
            }
        }
    }

    mutating func requeueStalled(now: ContinuousClock.Instant) -> [Int] {
        var stalled: [Int] = []
        for (index, piece) in active where !piece.verifying {
            let timeout = urgentPieces.contains(index) ? Self.urgentStallTimeout : Self.stallTimeout
            guard now - piece.lastProgress >= timeout else { continue }
            stalled.append(index)
            active[index]?.cursor = 0
            active[index]?.lastProgress = now
            for begin in blockOffsets(of: index) {
                requesters.removeValue(forKey: BlockKey(index: index, begin: begin))
            }
        }
        return stalled.sorted()
    }

    private mutating func nextBlock(in index: Int, excluding excluded: Set<BlockKey>) -> Block? {
        guard var piece = active[index], !piece.verifying else { return nil }
        defer { active[index] = piece }
        let length = metainfo.length(ofPiece: index)
        while piece.cursor < length {
            let begin = piece.cursor
            piece.cursor += PeerMessage.blockSize
            guard !piece.received.contains(begin), !excluded.contains(BlockKey(index: index, begin: begin)) else { continue }
            return block(in: index, at: begin)
        }
        let limit = urgentPieces.contains(index) ? Self.maxUrgentRedundancy : Self.maxRedundancy
        for begin in blockOffsets(of: index) where !piece.received.contains(begin) {
            let key = BlockKey(index: index, begin: begin)
            if !excluded.contains(key), (requesters[key]?.count ?? 0) < limit {
                return block(in: index, at: begin)
            }
        }
        return nil
    }

    private mutating func register(_ block: Block, for peer: UUID) -> Block {
        let key = BlockKey(index: block.index, begin: block.begin)
        inFlight[peer, default: []].insert(key)
        requesters[key, default: []].insert(peer)
        return block
    }

    private mutating func removeRequester(_ peer: UUID, of key: BlockKey) {
        requesters[key]?.remove(peer)
        if requesters[key]?.isEmpty == true {
            requesters.removeValue(forKey: key)
        }
    }

    private mutating func deactivate(_ index: Int) {
        active.removeValue(forKey: index)
        for begin in blockOffsets(of: index) {
            requesters.removeValue(forKey: BlockKey(index: index, begin: begin))
        }
        for peer in inFlight.keys {
            inFlight[peer] = inFlight[peer]?.filter { $0.index != index }
        }
    }

    private func block(in index: Int, at begin: Int) -> Block {
        Block(index: index, begin: begin, length: min(PeerMessage.blockSize, metainfo.length(ofPiece: index) - begin))
    }

    private func blockOffsets(of index: Int) -> StrideTo<Int> {
        stride(from: 0, to: metainfo.length(ofPiece: index), by: PeerMessage.blockSize)
    }
}
