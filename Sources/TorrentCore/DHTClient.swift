import Foundation
import CryptoKit
import Bencode

public enum DHTError: Error, Sendable {
    case noBootstrapNodes
    case timeout
}

public actor DHTClient {
    public static let bootstrapNodes: [(host: String, port: UInt16)] = [
        ("router.bittorrent.com", 6881),
        ("router.utorrent.com", 6881),
        ("dht.transmissionbt.com", 6881),
        ("212.129.33.59", 6881),
        ("87.98.162.88", 6881),
        ("104.236.203.73", 6881),
        ("5.9.106.114", 6881),
    ]

    static let maxCachedPeers = 500

    struct PeerCacheEntry: Equatable {
        let peer: PeerAddress
        var good: Bool
    }

    private struct PendingQuery {
        let continuation: CheckedContinuation<[String: BValue], any Error>
        let timeoutTask: Task<Void, Never>
    }

    public nonisolated let nodeID: Data
    public nonisolated let localPort: UInt16
    private let socket: UDPSocket
    private let k = 20
    private let queryTimeout = Duration.milliseconds(2500)
    private let nodeCacheURL: URL
    private let peerCacheURL: URL
    private let tokenSecret = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
    private var table: RoutingTable
    private var pending: [Data: PendingQuery] = [:]
    private var cachedPeersByHash: [String: [PeerCacheEntry]]
    private var announceTokens: [Data: [KRPCNodeInfo: Data]] = [:]

    public init(nodeID: Data = DHTClient.randomNodeID(), port: UInt16 = 0, cacheURL: URL? = nil, peerCacheURL: URL? = nil) throws {
        let socket = try UDPSocket()
        try socket.bind(port: port)
        self.nodeID = nodeID
        self.socket = socket
        localPort = socket.localPort
        nodeCacheURL = cacheURL ?? Self.cacheFile(named: "stupid-torrent-dht.nodes")
        self.peerCacheURL = peerCacheURL ?? Self.cacheFile(named: "stupid-torrent-dht.peers")
        table = Self.loadNodeCache(url: nodeCacheURL, localID: nodeID)
        cachedPeersByHash = Self.loadPeerCache(url: self.peerCacheURL)
        let datagrams = socket.datagrams(name: "dht-receive")
        Task { [weak self] in
            for await datagram in datagrams {
                await self?.handle(datagram)
            }
        }
    }

    static func cacheFile(named name: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(name)
    }

    public static func randomNodeID() -> Data {
        Data((0..<20).map { _ in UInt8.random(in: 0...255) })
    }

    public var nodeCount: Int { table.count }

    public func addNode(_ node: KRPCNodeInfo) {
        table.add(node)
    }

    public func stop() {
        for query in pending.values {
            query.timeoutTask.cancel()
            query.continuation.resume(throwing: DHTError.timeout)
        }
        pending.removeAll()
        saveNodeCache()
        savePeerCache()
        socket.close()
    }

    public func bootstrap(timeout: TimeInterval = 10) async {
        let unknownID = Data(repeating: 0, count: 20)
        var queried = Set<KRPCNodeInfo>()
        var frontier = Self.bootstrapNodes.map { KRPCNodeInfo(id: unknownID, host: $0.host, port: $0.port) }
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let batch = Array(frontier.filter { !queried.contains($0) }.prefix(8))
            guard !batch.isEmpty else { break }
            queried.formUnion(batch)
            for (_, reply) in await queryAll(batch, query: .findNode(id: nodeID, target: nodeID)) {
                addNodes(from: reply)
            }
            if table.count == 0, batch.allSatisfy({ $0.id == unknownID }) {
                queried.removeAll()
            }
            frontier = Array(table.allNodes.filter { !queried.contains($0) }.prefix(100))
        }
        saveNodeCache()
    }

    public func cachedPeers(infoHash: Data) -> [PeerAddress] {
        (cachedPeersByHash[infoHash.hexString] ?? []).map(\.peer)
    }

    public func cacheKnownGood(_ peers: [PeerAddress], for infoHash: Data) {
        cachePeers(peers, for: infoHash, good: true)
        savePeerCache()
    }

    public func lookup(infoHash: Data, timeout: TimeInterval = 15, onPeers: (@Sendable ([PeerAddress]) async -> Void)? = nil) async throws -> [PeerAddress] {
        try await ensureBootstrapped(timeout: timeout)
        var peers = Set<PeerAddress>()
        var queried = Set<KRPCNodeInfo>()
        var tokens: [KRPCNodeInfo: Data] = [:]
        var candidates = table.closest(to: infoHash, count: k)
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let batch = Array(candidates.filter { !queried.contains($0) }.prefix(16))
            guard !batch.isEmpty else { break }
            queried.formUnion(batch)
            var newNodes: [KRPCNodeInfo] = []
            var newPeers: [PeerAddress] = []
            for (node, reply) in await queryAll(batch, query: .getPeers(id: nodeID, infoHash: infoHash)) {
                if let id = reply["id"]?.stringValue {
                    let responder = KRPCNodeInfo(id: id, host: node.host, port: node.port)
                    table.add(responder)
                    if let token = reply["token"]?.stringValue {
                        tokens[responder] = token
                    }
                }
                for case .string(let compact) in reply["values"]?.listValue ?? [] {
                    newPeers += PeerAddress.parseCompact(compact).filter { peers.insert($0).inserted }
                }
                newNodes += addNodes(from: reply)
            }
            if !newPeers.isEmpty, let onPeers {
                await onPeers(newPeers)
            }
            candidates = Array(Set(candidates).union(newNodes).sorted { isCloser($0.id, than: $1.id, to: infoHash) }.prefix(k * 2))
            if peers.count >= 200 { break }
        }
        announceTokens[infoHash] = tokens
        cachePeers(Array(peers), for: infoHash, good: false)
        saveNodeCache()
        return Array(peers)
    }

    public func announce(infoHash: Data, port: UInt16, timeout: TimeInterval = 10) async throws {
        try await ensureBootstrapped(timeout: timeout)
        let closeNodes = table.closest(to: infoHash, count: k)
        let known = announceTokens[infoHash] ?? [:]
        let tokenNodes = closeNodes.compactMap { node in known[node].map { (node: node, token: $0) } }
        let missing = closeNodes.filter { known[$0] == nil }.prefix(8)
        let fetched = await queryAll(Array(missing), query: .getPeers(id: nodeID, infoHash: infoHash)).compactMap { node, reply in
            reply["token"]?.stringValue.map { (node: node, token: $0) }
        }
        let targets = Array((tokenNodes + fetched).prefix(k))
        TorrentLog.log("DHT: announce \(infoHash.hexString.prefix(8)) to \(targets.count) nodes")
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    _ = try? await self.query(.announcePeer(id: self.nodeID, infoHash: infoHash, port: port, token: target.token), to: target.node)
                }
            }
        }
        saveNodeCache()
    }

    func query(_ query: KRPCQuery, to node: KRPCNodeInfo) async throws -> [String: BValue] {
        var transaction = Self.randomTransactionID()
        while pending[transaction] != nil {
            transaction = Self.randomTransactionID()
        }
        let packet = KRPCWire.encode(query: query, transaction: transaction)
        let timeout = queryTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self, transaction] in
                try? await Task.sleep(for: timeout)
                await self?.resolve(transaction: transaction, with: .failure(DHTError.timeout))
            }
            pending[transaction] = PendingQuery(continuation: continuation, timeoutTask: timeoutTask)
            do {
                try socket.send(packet, to: node.address)
            } catch {
                resolve(transaction: transaction, with: .failure(error))
            }
        }
    }

    static func mergedPeerCache(_ existing: [PeerCacheEntry], adding peers: [PeerAddress], good: Bool) -> [PeerCacheEntry] {
        var list = existing
        var fresh: [PeerCacheEntry] = []
        let positions = Dictionary(list.enumerated().map { ($1.peer, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set(positions.keys)
        for peer in peers {
            if let index = positions[peer] {
                if good { list[index].good = true }
            } else if seen.insert(peer).inserted {
                fresh.append(PeerCacheEntry(peer: peer, good: good))
            }
        }
        let ordered = list.filter(\.good) + fresh.filter(\.good) + fresh.filter { !$0.good } + list.filter { !$0.good }
        return Array(ordered.prefix(maxCachedPeers))
    }

    private func cachePeers(_ peers: [PeerAddress], for infoHash: Data, good: Bool) {
        guard !peers.isEmpty else { return }
        let key = infoHash.hexString
        cachedPeersByHash[key] = Self.mergedPeerCache(cachedPeersByHash[key] ?? [], adding: peers, good: good)
    }

    private func ensureBootstrapped(timeout: TimeInterval) async throws {
        if table.count == 0 {
            await bootstrap(timeout: min(timeout / 2, 8))
        }
        guard table.count > 0 else { throw DHTError.noBootstrapNodes }
    }

    private func queryAll(_ nodes: [KRPCNodeInfo], query: KRPCQuery) async -> [(node: KRPCNodeInfo, reply: [String: BValue])] {
        await withTaskGroup(of: (KRPCNodeInfo, [String: BValue]?).self) { group in
            for node in nodes {
                group.addTask { (node, try? await self.query(query, to: node)) }
            }
            var replies: [(node: KRPCNodeInfo, reply: [String: BValue])] = []
            for await (node, reply) in group {
                if let reply { replies.append((node, reply)) }
            }
            return replies
        }
    }

    @discardableResult
    private func addNodes(from reply: [String: BValue]) -> [KRPCNodeInfo] {
        guard let compact = reply["nodes"]?.stringValue else { return [] }
        let nodes = CompactNode.parse(compact).filter { $0.id != nodeID }
        nodes.forEach { table.add($0) }
        return nodes
    }

    private func resolve(transaction: Data, with result: Result<[String: BValue], any Error>) {
        guard let query = pending.removeValue(forKey: transaction) else { return }
        query.timeoutTask.cancel()
        query.continuation.resume(with: result)
    }

    private func handle(_ datagram: Datagram) {
        guard let message = try? KRPCWire.decode(datagram.data) else { return }
        switch message {
        case .query(let transaction, let name, let args):
            handleQuery(name: name, args: args, transaction: transaction, from: datagram.sender)
        case .response(let transaction, let reply):
            resolve(transaction: transaction, with: .success(reply))
        case .error(let transaction, let code, let text):
            resolve(transaction: transaction, with: .failure(KRPCError.errorResponse(code: code, message: text)))
        }
    }

    private func token(for infoHash: Data) -> Data {
        Data(Insecure.SHA1.hash(data: tokenSecret + infoHash))
    }

    private func handleQuery(name: String, args: [String: BValue], transaction: Data, from sender: PeerAddress) {
        if let id = args["id"]?.stringValue, id.count == 20 {
            table.add(KRPCNodeInfo(id: id, host: sender.host, port: sender.port))
        }
        switch name {
        case "ping":
            respond(transaction: transaction, reply: ["id": .string(nodeID)], to: sender)
        case "find_node":
            guard let target = args["target"]?.stringValue, target.count == 20 else { return }
            let nodes = CompactNode.encode(table.closest(to: target, count: k))
            respond(transaction: transaction, reply: ["id": .string(nodeID), "nodes": .string(nodes)], to: sender)
        case "get_peers":
            guard let infoHash = args["info_hash"]?.stringValue, infoHash.count == 20 else { return }
            var reply: [String: BValue] = [
                "id": .string(nodeID),
                "token": .string(token(for: infoHash)),
                "nodes": .string(CompactNode.encode(table.closest(to: infoHash, count: k))),
            ]
            let peers = Array(cachedPeers(infoHash: infoHash).prefix(50))
            if !peers.isEmpty {
                reply["values"] = .string(PeerAddress.encodeCompact(peers))
            }
            respond(transaction: transaction, reply: reply, to: sender)
        case "announce_peer":
            guard let infoHash = args["info_hash"]?.stringValue, infoHash.count == 20,
                  args["token"]?.stringValue == token(for: infoHash) else {
                send(KRPCWire.encodeError(transaction: transaction, code: 203, message: "bad token"), to: sender)
                return
            }
            let announcedPort = args["port"]?.intValue ?? 0
            let implied = (args["implied_port"]?.intValue ?? 0) != 0
            let peerPort = implied || announcedPort == 0 ? sender.port : UInt16(clamping: announcedPort)
            TorrentLog.log("DHT: announce_peer for \(infoHash.hexString.prefix(8)) from \(sender.host):\(peerPort)")
            cachePeers([PeerAddress(host: sender.host, port: peerPort)], for: infoHash, good: false)
            respond(transaction: transaction, reply: ["id": .string(nodeID)], to: sender)
        default:
            break
        }
    }

    private func respond(transaction: Data, reply: [String: BValue], to destination: PeerAddress) {
        send(KRPCWire.encodeResponse(transaction: transaction, reply: reply), to: destination)
    }

    private func send(_ packet: Data, to destination: PeerAddress) {
        try? socket.send(packet, to: destination)
    }

    private func saveNodeCache() {
        let nodes = Array(table.allNodes.prefix(100))
        guard !nodes.isEmpty else { return }
        try? CompactNode.encode(nodes).write(to: nodeCacheURL)
    }

    private func savePeerCache() {
        let lines = cachedPeersByHash.flatMap { hash, entries in
            entries.map { "\(hash) \($0.peer.host) \($0.peer.port) \($0.good ? 1 : 0)" }
        }.prefix(5000)
        guard !lines.isEmpty else { return }
        try? Data(lines.joined(separator: "\n").utf8).write(to: peerCacheURL)
    }

    private static func loadNodeCache(url: URL, localID: Data) -> RoutingTable {
        var table = RoutingTable(localID: localID)
        if let data = try? Data(contentsOf: url) {
            CompactNode.parse(data).filter { $0.id != localID }.forEach { table.add($0) }
        }
        return table
    }

    private static func loadPeerCache(url: URL) -> [String: [PeerCacheEntry]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var cache: [String: [PeerCacheEntry]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[0].count == 40, let port = UInt16(parts[2]) else { continue }
            let entry = PeerCacheEntry(peer: PeerAddress(host: String(parts[1]), port: port), good: parts.count >= 4 && parts[3] == "1")
            cache[String(parts[0]), default: []].append(entry)
        }
        return cache
    }

    private static func randomTransactionID() -> Data {
        Data((0..<4).map { _ in UInt8.random(in: 0...255) })
    }
}
