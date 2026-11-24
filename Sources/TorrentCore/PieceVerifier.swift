import Foundation

public enum PieceVerifier {
    public struct Result: Sendable {
        public let ok: [Int]
        public let bad: [Int]
        public let missing: [Int]
    }

    public static func verify(metainfo: Metainfo, directory: URL) async throws -> Result {
        let storage = Storage(directory: directory, metainfo: metainfo)
        try await storage.prepare()
        var ok: [Int] = []
        var bad: [Int] = []
        var missing: [Int] = []
        for piece in 0..<metainfo.pieceCount {
            switch try? await storage.verify(piece: piece) {
            case true?: ok.append(piece)
            case false?: bad.append(piece)
            case nil: missing.append(piece)
            }
        }
        await storage.close()
        return Result(ok: ok, bad: bad, missing: missing)
    }
}
