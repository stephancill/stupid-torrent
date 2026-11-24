import Foundation

public struct PeerConnection: Sendable {
    public let transport: any PeerTransport
    public let address: PeerAddress
    public let remote: Handshake
}

enum PeerConnectError: Error, Sendable {
    case unreachable(any Error)
}

struct PeerConnector: Sendable {
    let infoHash: Data
    let peerID: Data
    let utp: UTPTransport?
    let connectTimeout: Duration
    let handshakeTimeout: Duration

    func connect(to address: PeerAddress) async throws -> PeerConnection {
        do {
            return try await race(to: address)
        } catch PeerConnectError.unreachable(let error) {
            throw error
        } catch {
            let connection = try await connectTCP(to: address, encrypted: false)
            TorrentLog.log("\(address.host): plaintext TCP handshake ok after encrypted attempt failed")
            return connection
        }
    }

    func accept(_ transport: any PeerTransport, from address: PeerAddress, encrypted: Bool) async throws -> PeerConnection {
        try await handshake(over: transport, with: address, encrypted: encrypted, isInitiator: false)
    }

    private func race(to address: PeerAddress) async throws -> PeerConnection {
        try await withThrowingTaskGroup(of: PeerConnection?.self) { group in
            group.addTask {
                do {
                    return try await connectTCP(to: address, encrypted: true)
                } catch PeerConnectError.unreachable {
                    return nil
                }
            }
            if let utp {
                group.addTask {
                    try? await connectUTP(utp, to: address)
                }
            }
            var winner: PeerConnection?
            var failure: (any Error)?
            while true {
                let result: PeerConnection??
                do {
                    result = try await group.next()
                } catch {
                    failure = failure ?? error
                    continue
                }
                guard let result else { break }
                guard let connection = result else { continue }
                if winner == nil {
                    winner = connection
                    group.cancelAll()
                } else {
                    connection.transport.close()
                }
            }
            if let winner { return winner }
            throw failure ?? PeerConnectError.unreachable(PeerStreamError.closed)
        }
    }

    private func connectTCP(to address: PeerAddress, encrypted: Bool) async throws -> PeerConnection {
        let stream = try PeerStream()
        return try await withTaskCancellationHandler {
            do {
                try await stream.connect(host: address.host, port: address.port, timeout: connectTimeout.timeInterval)
            } catch {
                stream.close()
                throw PeerConnectError.unreachable(error)
            }
            return try await handshake(over: stream, with: address, encrypted: encrypted, isInitiator: true)
        } onCancel: {
            stream.close()
        }
    }

    private func connectUTP(_ utp: UTPTransport, to address: PeerAddress) async throws -> PeerConnection {
        let connection = await utp.connect(to: address)
        return try await withTaskCancellationHandler {
            do {
                try await connection.startAsInitiator(timeout: connectTimeout)
            } catch {
                connection.close()
                throw PeerConnectError.unreachable(error)
            }
            return try await handshake(over: connection, with: address, encrypted: false, isInitiator: true)
        } onCancel: {
            connection.close()
        }
    }

    private func handshake(over transport: any PeerTransport, with address: PeerAddress, encrypted: Bool, isInitiator: Bool) async throws -> PeerConnection {
        let infoHash = infoHash
        let local = Handshake.make(infoHash: infoHash, peerID: peerID)
        do {
            let remote = try await withTimeout(handshakeTimeout, onCancel: { transport.close() }) {
                if encrypted, let stream = transport as? PeerStream {
                    do {
                        _ = isInitiator
                            ? try await MSEHandshake.initiate(stream: stream, infoHash: infoHash)
                            : try await MSEHandshake.respond(stream: stream, infoHash: infoHash)
                    } catch MSEError.plaintextFallback {}
                }
                if isInitiator {
                    try await transport.send(local.encode())
                }
                let remote = try Handshake.parse(try await transport.read(exactly: Handshake.length))
                guard remote.infoHash == infoHash else { throw PeerWireError.wrongInfoHash }
                if !isInitiator {
                    try await transport.send(local.encode())
                }
                return remote
            }
            return PeerConnection(transport: transport, address: address, remote: remote)
        } catch {
            transport.close()
            throw error
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
