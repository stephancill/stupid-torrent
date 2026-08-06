import Foundation

/// Sequential piece picker. Walks pieces in order (wrapping), skipping pieces that are verified
/// or already requested, so multiple peers end up on different pieces of the same sequential stream.
/// Priority pieces (e.g. the streamer's current window / moov tail) are served first.
public struct PiecePicker: Sendable {
    public let pieceCount: Int
    public var verified: Bitfield
    public var requested: Bitfield
    public var priority: Set<Int>
    public var cursor: Int

    public init(pieceCount: Int, verified: [Bool], requested: [Bool] = []) {
        self.pieceCount = pieceCount
        self.verified = Bitfield(bits: verified)
        if requested.isEmpty {
            self.requested = Bitfield(count: pieceCount)
        } else {
            self.requested = Bitfield(bits: requested)
        }
        self.priority = []
        self.cursor = 0
    }

    public mutating func nextPiece() -> Int? {
        guard pieceCount > 0 else { return nil }
        // Priority pieces first, lowest index first.
        for piece in priority.sorted() {
            if !verified[piece] && !requested[piece] {
                cursor = (piece + 1) % pieceCount
                return piece
            }
        }
        for offset in 0..<pieceCount {
            let index = (cursor + offset) % pieceCount
            if !verified[index] && !requested[index] {
                cursor = (index + 1) % pieceCount
                return index
            }
        }
        return nil
    }

    public mutating func markRequested(_ piece: Int) {
        requested[piece] = true
    }

    public mutating func markVerified(_ piece: Int) {
        verified[piece] = true
        requested[piece] = false
        priority.remove(piece)
    }

    public mutating func clearRequested(_ piece: Int) {
        requested[piece] = false
    }
}
