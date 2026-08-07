import Foundation

/// Shared UDP transport for all µTP connections. Demuxes incoming datagrams to the right
/// `UTPConnection` by (remote address, connid), runs a retransmit ticker, and provides the raw
/// `send` primitive connections use. The receive loop runs on a detached task (not a raw `Thread`)
/// so it can hop into the actor to dispatch packets — the `UDPSocket` is `@unchecked Sendable`, so
/// the blocking socket read lives outside the actor's executor.
public actor UTPTransport {
    public let socket: UDPSocket
    private var connections: [UTPConnectionKey: UTPConnection] = [:]
    private var isListening = false
    private var receiveTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    /// Called when a remote peer initiates a connection (SYN received). The connection is
    /// pre-registered and the SYNACK already sent; it becomes `.connected` on the first DATA.
    public let onAccept: (@Sendable (UTPConnection, PeerAddress) async -> Void)?

    public struct UTPConnectionKey: Hashable, Sendable {
        public let host: String
        public let port: UInt16
        public let connID: UInt16
        public init(host: String, port: UInt16, connID: UInt16) {
            self.host = host
            self.port = port
            self.connID = connID
        }
    }

    public init(socket: UDPSocket, onAccept: (@Sendable (UTPConnection, PeerAddress) async -> Void)? = nil) {
        self.socket = socket
        self.onAccept = onAccept
    }

    public func start() {
        guard !isListening else { return }
        isListening = true
        receiveTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runReceiveLoop()
        }
        startTicker()
    }

    public func stop() {
        isListening = false
        tickerTask?.cancel()
        tickerTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket.close()
    }

    public func send(_ data: Data, to peer: PeerAddress) throws {
        try socket.send(data, to: peer.host, port: peer.port)
    }

    /// Initiator factory: creates a µTP connection to `remote` (recvID = seed, sendID = seed + 1),
    /// registers it for demux, and returns it. The caller then runs `startAsInitiator()`.
    @discardableResult
    public func connect(to remote: PeerAddress) async -> UTPConnection {
        let seed = UInt16.random(in: 0...UInt16.max)
        let connection = UTPConnection(
            transport: self,
            remote: remote,
            recvID: seed,
            sendID: seed &+ 1,
            isInitiator: true
        )
        connections[UTPConnectionKey(host: remote.host, port: remote.port, connID: seed)] = connection
        startTicker()
        return connection
    }

    public func unregister(_ key: UTPConnectionKey) {
        connections.removeValue(forKey: key)
    }

    private func startTicker() {
        guard tickerTask == nil else { return }
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.tick()
            }
        }
    }

    private func tick() async {
        for connection in connections.values {
            await connection.nudge()
        }
    }

    /// Nonisolated so the blocking `socket.receiveFrom` runs on the detached task, not the actor.
    private nonisolated func runReceiveLoop() async {
        while true {
            do {
                guard let received = try socket.receiveFrom(timeout: 1) else { continue }
                await handleIncoming(received.data, fromHost: received.host, port: received.port)
            } catch {
                return
            }
        }
    }

    private func handleIncoming(_ data: Data, fromHost host: String, port: UInt16) async {
        guard let packet = UTP.decode(data) else { return }
        let source = PeerAddress(host: host, port: port)
        switch packet.type {
        case .syn:
            await handleIncomingSYN(packet, from: source)
        case .reset:
            await handleReset(packet, from: source)
        default:
            await handleIncomingData(packet, from: source)
        }
    }

    private func handleIncomingSYN(_ packet: UTP.Packet, from source: PeerAddress) async {
        // The initiator's SYN carries its recv id. We respond as recvID = id + 1, sendID = id
        // (libutp `utp_initialize_socket(..., false, id, id+1, id)`).
        let id = packet.connectionID
        let recvID = id &+ 1
        guard connections[UTPConnectionKey(host: source.host, port: source.port, connID: recvID)] == nil else {
            return
        }
        let connection = UTPConnection(
            transport: self,
            remote: source,
            recvID: recvID,
            sendID: id,
            isInitiator: false
        )
        connections[UTPConnectionKey(host: source.host, port: source.port, connID: recvID)] = connection
        await connection.accept(packet: packet)
        if let onAccept {
            // Run the accept handler off the transport actor so a long-lived session (e.g. a
            // BitTorrent PeerSession) never blocks demuxing of further datagrams.
            Task { await onAccept(connection, source) }
        }
    }

    private func handleIncomingData(_ packet: UTP.Packet, from source: PeerAddress) async {
        let key = UTPConnectionKey(host: source.host, port: source.port, connID: packet.connectionID)
        guard let connection = connections[key] else {
            sendReset(for: packet, to: source)
            return
        }
        await connection.receive(packet: packet)
    }

    private func handleReset(_ packet: UTP.Packet, from source: PeerAddress) async {
        let id = packet.connectionID
        if let connection = lookupConnection(for: id, from: source) {
            await connection.receive(packet: packet)
        }
    }

    /// libutp looks up RST by the raw id, then by id±1 when the id matches a socket's send id.
    private func lookupConnection(for id: UInt16, from source: PeerAddress) -> UTPConnection? {
        let host = source.host
        let port = source.port
        if let connection = connections[UTPConnectionKey(host: host, port: port, connID: id)] {
            return connection
        }
        if let connection = connections[UTPConnectionKey(host: host, port: port, connID: id &+ 1)], connection.sendID == id {
            return connection
        }
        if let connection = connections[UTPConnectionKey(host: host, port: port, connID: id &- 1)], connection.sendID == id {
            return connection
        }
        return nil
    }

    private func sendReset(for packet: UTP.Packet, to source: PeerAddress) {
        let rst = UTP.Packet(
            type: .reset,
            connectionID: packet.connectionID,
            timestamp: packet.timestamp,
            replyMicro: 0,
            windowSize: 0,
            seqNr: 0,
            ackNr: packet.seqNr
        )
        try? socket.send(UTP.encode(rst), to: source.host, port: source.port)
    }
}
