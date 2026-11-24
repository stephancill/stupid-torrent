import Foundation

public struct UDPTrackerClient: TrackerClient {
    private let tracker: PeerAddress

    public init(host: String, port: UInt16) {
        tracker = PeerAddress(host: host, port: port)
    }

    public func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse {
        let tracker = tracker
        return try await BlockingIO.run(name: "udp-tracker") {
            try Self.announceBlocking(request, tracker: tracker)
        }
    }

    private static func announceBlocking(_ request: AnnounceRequest, tracker: PeerAddress) throws -> AnnounceResponse {
        let socket = try UDPSocket()
        defer { socket.close() }

        let connectTxn = randomTransactionID()
        var connectRequest = Data()
        connectRequest.appendUInt64BE(0x4172_7101_980)
        connectRequest.appendUInt32BE(0)
        connectRequest.appendUInt32BE(UInt32(bitPattern: connectTxn))
        try socket.send(connectRequest, to: tracker)
        guard let connectResponse = try socket.receive(timeout: 5)?.data, connectResponse.count >= 16,
              connectResponse.readUInt32BE(at: 0) == 0,
              connectResponse.readInt32BE(at: 4) == connectTxn else {
            throw TrackerError.malformedResponse("bad UDP connect response")
        }
        let connectionID = connectResponse.readUInt64BE(at: 8)

        let announceTxn = randomTransactionID()
        var announce = Data()
        announce.appendUInt64BE(connectionID)
        announce.appendUInt32BE(1)
        announce.appendUInt32BE(UInt32(bitPattern: announceTxn))
        announce.append(request.infoHash)
        announce.append(request.peerID)
        announce.appendInt64BE(request.downloaded)
        announce.appendInt64BE(request.left)
        announce.appendInt64BE(request.uploaded)
        announce.appendUInt32BE(UInt32(request.event.rawValue))
        announce.appendUInt32BE(0)
        announce.appendUInt32BE(UInt32(bitPattern: request.key))
        announce.appendUInt32BE(UInt32(request.numWant))
        announce.appendUInt16BE(request.port)

        try socket.send(announce, to: tracker)
        guard let response = try socket.receive(timeout: 5)?.data, response.count >= 20 else {
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
        return AnnounceResponse(
            interval: Int(response.readInt32BE(at: 8)),
            peers: PeerAddress.parseCompact(response.dropFirst(20)),
            seeders: Int(response.readInt32BE(at: 16)),
            leechers: Int(response.readInt32BE(at: 12))
        )
    }

    private static func randomTransactionID() -> Int32 {
        Int32.random(in: .min ... .max)
    }
}
