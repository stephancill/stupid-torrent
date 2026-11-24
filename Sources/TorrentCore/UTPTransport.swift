import Foundation

public actor UTPTransport {
    private struct ConnectionKey: Hashable {
        let remote: PeerAddress
        let connectionID: UInt16
    }

    private let socket: UDPSocket
    private let onAccept: (@Sendable (UTPConnection, PeerAddress) async -> Void)?
    private var connections: [ConnectionKey: UTPConnection] = [:]
    private var receiveTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?

    public init(socket: UDPSocket, onAccept: (@Sendable (UTPConnection, PeerAddress) async -> Void)? = nil) {
        self.socket = socket
        self.onAccept = onAccept
    }

    public func start() {
        guard receiveTask == nil else { return }
        let datagrams = socket.datagrams(name: "utp-receive")
        receiveTask = Task { [weak self] in
            for await datagram in datagrams {
                await self?.handle(datagram)
            }
        }
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.tick()
            }
        }
    }

    public func stop() {
        tickerTask?.cancel()
        tickerTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket.close()
    }

    public func connect(to remote: PeerAddress) -> UTPConnection {
        let seed = UInt16.random(in: 0...UInt16.max)
        let connection = UTPConnection(transport: self, remote: remote, recvID: seed, sendID: seed &+ 1, isInitiator: true)
        connections[ConnectionKey(remote: remote, connectionID: seed)] = connection
        return connection
    }

    nonisolated func send(_ data: Data, to peer: PeerAddress) throws {
        try socket.send(data, to: peer)
    }

    func unregister(_ connection: UTPConnection) {
        connections.removeValue(forKey: ConnectionKey(remote: connection.remote, connectionID: connection.recvID))
    }

    private func tick() async {
        for connection in connections.values {
            await connection.nudge()
        }
    }

    private func handle(_ datagram: Datagram) async {
        guard let packet = UTP.decode(datagram.data) else { return }
        let source = datagram.sender
        switch packet.type {
        case .syn:
            await handleSYN(packet, from: source)
        case .reset:
            await lookupResetTarget(id: packet.connectionID, from: source)?.receive(packet: packet)
        default:
            guard let connection = connections[ConnectionKey(remote: source, connectionID: packet.connectionID)] else {
                sendReset(for: packet, to: source)
                return
            }
            await connection.receive(packet: packet)
        }
    }

    private func handleSYN(_ packet: UTP.Packet, from source: PeerAddress) async {
        let id = packet.connectionID
        let key = ConnectionKey(remote: source, connectionID: id &+ 1)
        guard connections[key] == nil else { return }
        let connection = UTPConnection(transport: self, remote: source, recvID: id &+ 1, sendID: id, isInitiator: false)
        connections[key] = connection
        await connection.accept(packet: packet)
        if let onAccept {
            Task { await onAccept(connection, source) }
        }
    }

    private func lookupResetTarget(id: UInt16, from source: PeerAddress) -> UTPConnection? {
        if let connection = connections[ConnectionKey(remote: source, connectionID: id)] {
            return connection
        }
        return [id &+ 1, id &- 1].lazy
            .compactMap { self.connections[ConnectionKey(remote: source, connectionID: $0)] }
            .first { $0.sendID == id }
    }

    private func sendReset(for packet: UTP.Packet, to source: PeerAddress) {
        let reset = UTP.Packet(type: .reset, connectionID: packet.connectionID, timestamp: packet.timestamp, replyMicro: 0, windowSize: 0, seqNr: 0, ackNr: packet.seqNr)
        try? socket.send(UTP.encode(reset), to: source)
    }
}
