import Foundation
import Bencode

public final class HTTPTrackerClient: TrackerClient, @unchecked Sendable {
    private let url: URL
    private let session: URLSession

    public init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    public func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse {
        var query = url.absoluteString.contains("?") ? url.absoluteString + "&" : url.absoluteString + "?"
        query += HTTPTrackerClient.encodeQuery(request)
        guard let requestURL = URL(string: query) else {
            throw TrackerError.malformedResponse("invalid announce URL")
        }
        var urlRequest = URLRequest(url: requestURL)
        urlRequest.setValue("stupid-torrent-client/0.1", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw TrackerError.network(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TrackerError.network(URLError(.badServerResponse))
        }
        do {
            return try Self.parseResponse(data)
        } catch let error as TrackerError {
            throw error
        } catch {
            throw TrackerError.malformedResponse("bencode decode failed: \(error)")
        }
    }

    static func encodeQuery(_ request: AnnounceRequest) -> String {
        var components: [String] = []
        components.append("info_hash=" + percentEncode(request.infoHash))
        components.append("peer_id=" + percentEncode(request.peerID))
        components.append("port=\(request.port)")
        components.append("uploaded=\(request.uploaded)")
        components.append("downloaded=\(request.downloaded)")
        let left = request.left < 0 ? Int64.max : request.left
        components.append("left=\(left)")
        if let event = request.event.queryValue {
            components.append("event=\(event)")
        }
        components.append("compact=1")
        components.append("numwant=\(request.numWant)")
        components.append("key=\(request.key)")
        return components.joined(separator: "&")
    }

    static func percentEncode(_ data: Data) -> String {
        data.map { String(format: "%%%02X", $0) }.joined()
    }

    static func parseResponse(_ data: Data) throws -> AnnounceResponse {
        let root = try Bencode.decode(data)
        guard case .dictionary(let dict) = root else {
            throw TrackerError.malformedResponse("not a dict")
        }
        if let failure = dict["failure reason"]?.stringValueUTF8 {
            return AnnounceResponse(interval: 0, peers: [], seeders: nil, leechers: nil, failureReason: failure)
        }
        let interval = dict["interval"]?.intValue ?? dict["min interval"]?.intValue ?? 0
        let seeders = dict["complete"]?.intValue
        let leechers = dict["incomplete"]?.intValue

        var peers: [PeerAddress] = []
        if case .string(let compact)? = dict["peers"], compact.count % 6 == 0 {
            var offset = 0
            while offset < compact.count {
                let ip = [UInt8](compact[offset..<(offset + 4)])
                let port = (UInt16(compact[offset + 4]) << 8) | UInt16(compact[offset + 5])
                peers.append(PeerAddress(ipv4Bytes: ip, port: port))
                offset += 6
            }
        } else if case .list(let list)? = dict["peers"] {
            for case .dictionary(let peerDict) in list {
                guard let ip = peerDict["ip"]?.stringValueUTF8, let port = peerDict["port"]?.intValue else { continue }
                peers.append(PeerAddress(host: ip, port: UInt16(port)))
            }
        }
        if case .string(let compact6)? = dict["peers6"], compact6.count % 18 == 0 {
            var offset = 0
            while offset < compact6.count {
                let ip = [UInt8](compact6[offset..<(offset + 16)])
                let port = (UInt16(compact6[offset + 16]) << 8) | UInt16(compact6[offset + 17])
                peers.append(PeerAddress(ipv6Bytes: ip, port: port))
                offset += 18
            }
        }
        return AnnounceResponse(interval: interval, peers: peers, seeders: seeders, leechers: leechers, failureReason: nil)
    }
}
