import Foundation

public struct TorrentStatus: Sendable {
    public enum State: Sendable, Equatable {
        case metadata
        case downloading
        case seeding
        case paused
        case error(String)
    }

    public let name: String
    public let infoHash: Data
    public let state: State
    public let verifiedCount: Int
    public let pieceCount: Int
    public let peers: Int
    public let seeds: Int
    public let downloadRate: Double
    public let uploadRate: Double
    public let downloadedBytes: Int64
    public let uploadedBytes: Int64

    public init(
        name: String,
        infoHash: Data,
        state: State,
        verifiedCount: Int,
        pieceCount: Int,
        peers: Int,
        seeds: Int,
        downloadRate: Double,
        uploadRate: Double,
        downloadedBytes: Int64,
        uploadedBytes: Int64
    ) {
        self.name = name
        self.infoHash = infoHash
        self.state = state
        self.verifiedCount = verifiedCount
        self.pieceCount = pieceCount
        self.peers = peers
        self.seeds = seeds
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
    }

    public var progress: Double {
        pieceCount == 0 ? 0 : Double(verifiedCount) / Double(pieceCount)
    }

    public var isComplete: Bool {
        pieceCount > 0 && verifiedCount == pieceCount
    }
}
