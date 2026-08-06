import Foundation

public final class UDPTrackerClient: TrackerClient, @unchecked Sendable {
    private let host: String
    private let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse {
        let socket = try UDPSocket()
        defer { socket.close() }

        let connectTxn = Self.randomTransactionID()
        var connectRequest = Data()
        connectRequest.appendUInt64BE(0x4172_7101_980)
        connectRequest.appendUInt32BE(0) // action connect
        connectRequest.appendUInt32BE(UInt32(bitPattern: connectTxn))
        try socket.send(connectRequest, to: host, port: port)
        guard let connectResponse = try socket.receive(timeout: 15), connectResponse.count >= 16,
              connectResponse.readUInt32BE(at: 0) == 0,
              connectResponse.readInt32BE(at: 4) == connectTxn else {
            throw TrackerError.malformedResponse("bad UDP connect response")
        }
        let connectionID = connectResponse.readUInt64BE(at: 8)

        let announceTxn = Self.randomTransactionID()
        var announce = Data()
        announce.appendUInt64BE(connectionID)
        announce.appendUInt32BE(1) // action announce
        announce.appendUInt32BE(UInt32(bitPattern: announceTxn))
        announce.append(request.infoHash)
        announce.append(request.peerID)
        announce.appendInt64BE(request.downloaded)
        announce.appendInt64BE(request.left)
        announce.appendInt64BE(request.uploaded)
        announce.appendUInt32BE(UInt32(request.event.rawValue))
        announce.appendUInt32BE(0) // ip address
        announce.appendUInt32BE(UInt32(bitPattern: request.key))
        announce.appendUInt32BE(UInt32(request.numWant))
        announce.appendUInt16BE(request.port)

        try socket.send(announce, to: host, port: port)
        guard let response = try socket.receive(timeout: 15), response.count >= 20 else {
            throw TrackerError.malformedResponse("bad UDP announce response")
        }

        let action = response.readUInt32BE(at: 0)
        if action == 3 {
            let message = String(decoding: response.dropFirst(8), as: UTF8.self)
            throw TrackerError.failureReason(message)
        }
        guard action == 1, response.readInt32BE(at: 4) == announceTxn else {
            throw TrackerError.malformedResponse("bad UDP announce response")
        }
        let interval = Int(response.readInt32BE(at: 8))
        let leechers = Int(response.readInt32BE(at: 12))
        let seeders = Int(response.readInt32BE(at: 16))

        var peers: [PeerAddress] = []
        var offset = 20
        while offset + 6 <= response.count {
            let ip = [UInt8](response[offset..<(offset + 4)])
            let port = response.readUInt16BE(at: offset + 4)
            peers.append(PeerAddress(ipv4Bytes: ip, port: port))
            offset += 6
        }
        return AnnounceResponse(interval: interval, peers: peers, seeders: seeders, leechers: leechers, failureReason: nil)
    }

    private static func randomTransactionID() -> Int32 {
        Int32.random(in: .min ... .max)
    }
}
