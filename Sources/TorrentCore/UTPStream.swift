import Foundation

/// A byte-stream adapter over a µTP connection exposing the same send/read/close surface as
/// `PeerStream`, so `PeerSession` can run the BitTorrent protocol over µTP as an alternative
/// transport (mirrors webtorrent's TCP/µTP peer transports in `lib/peer.js`).
public final class UTPStream: @unchecked Sendable, PeerTransport {
    private let connection: UTPConnection

    public init(connection: UTPConnection) {
        self.connection = connection
    }

    public func send(_ data: Data) async throws {
        _ = try await connection.write(data)
    }

    public func read(exactly count: Int) async throws -> Data {
        try await connection.read(exactly: count)
    }

    public func close() {
        Task {
            await connection.close()
            await connection.unregister()
        }
    }
}
