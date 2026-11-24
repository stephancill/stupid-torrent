import Foundation

public struct PiecePicker: Sendable {
    public var verified: Bitfield
    public var requested: Bitfield
    public var priority: [Int: Int] = [:]
    public var cursor = 0

    public init(verified: Bitfield) {
        self.verified = verified
        requested = Bitfield(count: verified.count)
    }

    public var pieceCount: Int { verified.count }

    public mutating func nextPiece() -> Int? {
        nextPiece(available: { _ in true })
    }

    public mutating func nextPiece(available: (Int) -> Bool) -> Int? {
        guard pieceCount > 0 else { return nil }
        let prioritized = priority.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for (piece, _) in prioritized where isWanted(piece) && available(piece) {
            cursor = (piece + 1) % pieceCount
            return piece
        }
        for offset in 0..<pieceCount {
            let index = (cursor + offset) % pieceCount
            if isWanted(index) && available(index) {
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

    public mutating func replacePriorities(with pieces: Range<Int>, level: Int) {
        priority.removeAll(keepingCapacity: true)
        for piece in pieces where !verified[piece] {
            priority[piece] = level
        }
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

    private func isWanted(_ piece: Int) -> Bool {
        !verified[piece] && !requested[piece]
    }
}
