import Foundation
import CryptoKit

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
            let start = piece * metainfo.pieceLength
            let length = min(metainfo.pieceLength, metainfo.totalLength - start)
            guard let data = try? await storage.read(piece: piece, offset: 0, length: length),
                  data.count == length else {
                missing.append(piece)
                continue
            }
            if Data(Insecure.SHA1.hash(data: data)) == metainfo.pieceHashes[piece] {
                ok.append(piece)
            } else {
                bad.append(piece)
            }
        }
        await storage.close()
        return Result(ok: ok, bad: bad, missing: missing)
    }
}
