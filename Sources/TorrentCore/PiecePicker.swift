import Foundation

/// Sequential piece picker. Walks pieces in order (wrapping), skipping pieces that are verified
/// or already requested, so multiple peers end up on different pieces of the same sequential stream.
/// Prioritized pieces (e.g. the streamer's current window / moov tail / seek targets) are served
/// first: highest priority level first, then lowest piece index within a level.
public struct PiecePicker: Sendable {
    public let pieceCount: Int
    public var verified: Bitfield
    public var requested: Bitfield
    /// Piece -> priority level. Higher levels are picked before lower ones.
    public var priority: [Int: Int]
    public var cursor: Int

    public init(pieceCount: Int, verified: [Bool], requested: [Bool] = []) {
        self.pieceCount = pieceCount
        self.verified = Bitfield(bits: verified)
        if requested.isEmpty {
            self.requested = Bitfield(count: pieceCount)
        } else {
            self.requested = Bitfield(bits: requested)
        }
        self.priority = [:]
        self.cursor = 0
    }

    public mutating func nextPiece() -> Int? {
        nextPiece(available: { _ in true })
    }

    /// Returns the next piece to request from a peer that only has certain pieces. `available`
    /// lets the caller restrict selection to pieces the peer actually holds (its bitfield), so we
    /// never request blocks a peer can't serve. Prioritized pieces win, then lowest index.
    public mutating func nextPiece(available: (Int) -> Bool) -> Int? {
        guard pieceCount > 0 else { return nil }
        // Prioritized pieces first: highest level, then lowest index within the level.
        for level in Set(priority.values).sorted(by: >) {
            for piece in priority.keys.filter({ priority[$0] == level }).sorted() {
                if !verified[piece] && !requested[piece] && available(piece) {
                    cursor = (piece + 1) % pieceCount
                    return piece
                }
            }
        }
        for offset in 0..<pieceCount {
            let index = (cursor + offset) % pieceCount
            if !verified[index] && !requested[index] && available(index) {
                cursor = (index + 1) % pieceCount
                return index
            }
        }
        return nil
    }

    public mutating func setPriority(_ piece: Int, level: Int) {
        guard !verified[piece] else { return }
        priority[piece] = max(priority[piece] ?? 0, level)
    }

    public mutating func markRequested(_ piece: Int) {
        requested[piece] = true
    }

    public mutating func markVerified(_ piece: Int) {
        verified[piece] = true
        requested[piece] = false
        priority.removeValue(forKey: piece)
    }

    public mutating func clearRequested(_ piece: Int) {
        requested[piece] = false
    }
}
