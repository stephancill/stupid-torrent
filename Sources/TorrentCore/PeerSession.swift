import Foundation

struct PeerSession: Sendable {
    let id = UUID()
    let connection: PeerConnection
    let torrent: Torrent

    func run() async {
        let transport = connection.transport
        let (outbox, continuation) = AsyncStream<Data>.makeStream()
        guard await torrent.register(self, outbox: continuation) else {
            transport.close()
            return
        }
        let writer = Task {
            for await data in outbox {
                do {
                    try await transport.send(data)
                } catch {
                    transport.close()
                    return
                }
            }
        }
        do {
            while true {
                await torrent.handle(try await transport.readMessage(), from: id)
            }
        } catch {
            TorrentLog.log("peer \(connection.address.host) dropped: \(error)")
        }
        transport.close()
        continuation.finish()
        writer.cancel()
        await torrent.unregister(id)
    }
}

extension PeerTransport {
    func readMessage() async throws -> PeerMessage? {
        let length = Int(try await read(exactly: 4).readUInt32BE(at: 0))
        guard length > 0 else { return nil }
        guard length <= PeerMessage.maxFrameLength else { throw PeerWireError.wrongLength }
        let body = try await read(exactly: length)
        return try? PeerMessage.decode(length: length, body: body)
    }
}
