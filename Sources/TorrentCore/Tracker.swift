import Foundation

public enum AnnounceEvent: Int32, Sendable {
    case none = 0
    case completed = 1
    case started = 2
    case stopped = 3

    public var queryValue: String? {
        switch self {
        case .none: nil
        case .completed: "completed"
        case .started: "started"
        case .stopped: "stopped"
        }
    }
}

public struct AnnounceRequest: Sendable, Equatable {
    public let infoHash: Data
    public let peerID: Data
    public let port: UInt16
    public let uploaded: Int64
    public let downloaded: Int64
    public let left: Int64
    public let event: AnnounceEvent
    public let numWant: Int
    public let key: Int32

    public init(infoHash: Data, peerID: Data, port: UInt16, uploaded: Int64 = 0, downloaded: Int64 = 0, left: Int64, event: AnnounceEvent = .none, numWant: Int = 50, key: Int32 = 0) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.port = port
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.left = left
        self.event = event
        self.numWant = numWant
        self.key = key
    }
}

public struct AnnounceResponse: Sendable {
    public let interval: Int
    public let peers: [PeerAddress]
    public let seeders: Int?
    public let leechers: Int?
    public let failureReason: String?
}

public enum TrackerError: Error, Sendable {
    case unsupportedScheme(String)
    case failureReason(String)
    case malformedResponse(String)
    case network(Error)
}

public protocol TrackerClient: Sendable {
    func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse
}

public enum TrackerClientFactory {
    public static func makeClient(for url: URL) throws -> any TrackerClient {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return HTTPTrackerClient(url: url)
        case "udp":
            guard let host = url.host, let port = url.port else {
                throw TrackerError.malformedResponse("UDP tracker URL missing host/port: \(url)")
            }
            return UDPTrackerClient(host: host, port: UInt16(port))
        default:
            throw TrackerError.unsupportedScheme(url.scheme ?? "none")
        }
    }
}
