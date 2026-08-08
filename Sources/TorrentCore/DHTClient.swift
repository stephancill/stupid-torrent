import Foundation
import CryptoKit
import Bencode

public enum DHTError: Error, Sendable {
    case noBootstrapNodes
    case noNodesToQuery
    case notListening
    case timeout
}

/// A minimal BEP 5 DHT client: UDP KRPC transport, Kademlia routing table, bootstrap via the
/// well-known router nodes, and iterative `get_peers` lookups that yield torrent peer addresses.
public final class DHTClient: @unchecked Sendable {
    public static let bootstrapNodes: [(host: String, port: UInt16)] = [
        ("router.bittorrent.com", 6881),
        ("router.utorrent.com", 6881),
        ("dht.transmissionbt.com", 6881),
        // Additional public nodes; the classic three are often filtered/unreachable.
        ("212.129.33.59", 6881),
        ("87.98.162.88", 6881),
        ("104.236.203.73", 6881),
        ("5.9.106.114", 6881),
    ]

    public let nodeID: Data
    private let socket: UDPSocket
    private let table: RoutingTable
    private let k = 20
    private let queryTimeout: TimeInterval = 2.5
    private let lock = NSLock()
    private var pending: [String: PendingQuery] = [:]
    private var isListening = false
    private var receiveThread: Thread?
    private let nodeCacheURL: URL
    private let peerCacheURL: URL
    private var cachedPeersByHash: [String: [PeerCacheEntry]] = [:]
    /// Per-process secret used to issue/verify `get_peers` tokens (BEP 5): unguessable per-infohash
    /// tokens let us serve `announce_peer` records (the live-peer store) without letting arbitrary
    /// peers poison the cache.
    private let tokenSecret = Data((0..<20).map { _ in UInt8.random(in: 0...255) })

    /// A cached peer plus a `good` flag: `good` peers completed a real connection (e.g. served
    /// metadata) and are retried before the raw `get_peers` records, most of which are stale/NAT'd.
    private struct PeerCacheEntry {
        let peer: PeerAddress
        var good: Bool
    }

    private struct PendingQuery {
        let node: KRPCNodeInfo
        let continuation: CheckedContinuation<[String: BValue], Error>
        let timeoutTask: Task<Void, Never>
    }

    public init(nodeID: Data = DHTClient.randomNodeID(), cacheURL: URL? = nil, peerCacheURL: URL? = nil) throws {
        self.nodeID = nodeID
        self.socket = try UDPSocket()
        self.table = RoutingTable(localID: nodeID, k: k)
        self.nodeCacheURL = cacheURL ?? Self.defaultCacheURL()
        self.peerCacheURL = peerCacheURL ?? Self.defaultPeerCacheURL()
        loadNodeCache()
        loadPeerCache()
    }

    /// Cache location shared by all DHT clients so a warm routing table survives restarts
    /// (mirrors bittorrent-dht's "persist the DHT to disk between restarts" recommendation).
    public static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("stupid-torrent-dht.nodes")
    }

    /// Cache of live torrent peers discovered via `get_peers`, keyed by infohash. Mirrors
    /// bittorrent-dht's peer store: emitting these before any network query is what lets warm
    /// magnet resolutions start from known-reachable peers.
    public static func defaultPeerCacheURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("stupid-torrent-dht.peers")
    }

    /// The persistent node identity, shared across launches. A stable node ID is what lets the
    /// node accumulate a real position in the DHT (nodes that learn us keep querying the same
    /// identity) instead of churning a fresh identity every cycle.
    public static func defaultNodeIDURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("stupid-torrent-dht.nodeid")
    }

    private func loadNodeCache() {
        guard let data = try? Data(contentsOf: nodeCacheURL), data.count >= 26 else { return }
        for node in CompactNode.parse(data) where node.id != nodeID {
            table.add(node)
        }
    }

    private func saveNodeCache() {
        let nodes = Array(table.allNodes.prefix(100))
        guard !nodes.isEmpty else { return }
        try? CompactNode.encode(nodes).write(to: nodeCacheURL)
    }

    /// Loads the persisted per-infohash live-peer cache (line format
    /// `<hash-hex40> <host> <port> [good]`).
    private func loadPeerCache() {
        guard let data = try? Data(contentsOf: peerCacheURL),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[0].count == 40, let port = UInt16(parts[2]) else { continue }
            cachedPeersByHash[String(parts[0]), default: []].append(
                PeerCacheEntry(peer: PeerAddress(host: String(parts[1]), port: port), good: parts.count >= 4 && parts[3] == "1")
            )
        }
        lock.unlock()
    }

    private func savePeerCache() {
        lock.lock()
        var lines: [String] = []
        var total = 0
        for (hash, peers) in cachedPeersByHash {
            for entry in peers {
                guard total < 5000 else { break }
                lines.append("\(hash) \(entry.peer.host) \(entry.peer.port) \(entry.good ? 1 : 0)")
                total += 1
            }
            if total >= 5000 { break }
        }
        lock.unlock()
        guard !lines.isEmpty else { return }
        try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: peerCacheURL)
    }

    private func cachePeers(_ peers: [PeerAddress], for infoHash: Data, good: Bool = false) {
        guard !peers.isEmpty else { return }
        lock.lock()
        let key = infoHash.hexString
        var list = cachedPeersByHash[key] ?? []
        var seen = Set(list.map(\.peer))
        for peer in peers where seen.insert(peer).inserted {
            list.append(PeerCacheEntry(peer: peer, good: good))
        }
        cachedPeersByHash[key] = Array(list.suffix(500))
        lock.unlock()
    }

    /// Marks peers as confirmed-reachable (completed a handshake / served metadata). Good peers
    /// are returned first by `cachedPeers`, so the next resolution for this infohash retries the
    /// peers that are known to work instead of re-draining stale `get_peers` records.
    public func cacheKnownGood(_ peers: [PeerAddress], for infoHash: Data) {
        guard !peers.isEmpty else { return }
        lock.lock()
        let key = infoHash.hexString
        var list = cachedPeersByHash[key] ?? []
        var seen = Set(list.map(\.peer))
        var upgraded = false
        for peer in peers {
            if let index = list.firstIndex(where: { $0.peer == peer }) {
                if !list[index].good {
                    list[index].good = true
                    upgraded = true
                }
            } else if seen.insert(peer).inserted {
                list.append(PeerCacheEntry(peer: peer, good: true))
                upgraded = true
            }
        }
        if upgraded {
            // Good peers go first so the next sweep tries them immediately.
            let good = list.filter(\.good)
            let rest = list.filter { !$0.good }
            cachedPeersByHash[key] = Array((good + rest).prefix(500))
        }
        lock.unlock()
        savePeerCache()
    }

    public static func randomNodeID() -> Data {
        Data((0..<20).map { _ in UInt8.random(in: 0...255) })
    }

    public var nodeCount: Int { table.count }

    /// Adds a known node to the routing table (e.g. from a peer's PORT message, or tests). Mirrors
    /// bittorrent-dht's `dht.addNode`.
    public func addNode(_ node: KRPCNodeInfo) {
        table.add(node)
    }

    /// The UDP port our socket is bound to (0 until `bind(port:)` is used). Used by tests and by
    /// callers that want the node reachable at a known address.
    public var localPort: UInt16 { socket.localPort }

    public func startListening(port: UInt16? = nil) {
        lock.lock()
        if isListening {
            lock.unlock()
            return
        }
        if let port {
            try? socket.bind(port: port)
        }
        isListening = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.receiveLoop()
        }
        thread.name = "dht-receive"
        receiveThread = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        isListening = false
        for (_, pendingQuery) in pending {
            pendingQuery.timeoutTask.cancel()
            pendingQuery.continuation.resume(throwing: DHTError.timeout)
        }
        pending.removeAll()
        lock.unlock()
        saveNodeCache()
        savePeerCache()
        socket.close()
    }

    /// Bootstraps the routing table by querying the well-known router nodes, then performs a
    /// `find_node` on ourselves to populate nearby buckets (mirrors bittorrent-dht `_bootstrap`).
    public func bootstrap(timeout: TimeInterval = 10) async throws {
        startListening()
        var queried = Set<KRPCNodeInfo>()
        var frontier = Self.bootstrapNodes.map {
            KRPCNodeInfo(id: Data(repeating: 0, count: 20), host: $0.host, port: $0.port)
        }
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline, !frontier.isEmpty, !Task.isCancelled {
            let batch = Array(frontier.filter { !queried.contains($0) }.prefix(8))
            guard !batch.isEmpty else { break }
            for node in batch {
                queried.insert(node)
            }
            await withTaskGroup(of: Void.self) { group in
                for node in batch {
                    group.addTask {
                        do {
                            let reply = try await self.query(.findNode(id: self.nodeID, target: self.nodeID), to: node)
                            if let nodes = reply["nodes"]?.stringValue {
                                for info in CompactNode.parse(nodes) where info.id != self.nodeID {
                                    self.table.add(info)
                                }
                            }
                        } catch {
                            // node unreachable; try the next one
                        }
                    }
                }
            }
            // Retry the seed nodes if the first wave found nothing (they're flaky).
            if table.count == 0, batch.allSatisfy({ $0.id == Data(repeating: 0, count: 20) }) {
                queried.removeAll()
            }
            frontier = Array(table.allNodes.filter { !queried.contains($0) }.prefix(100))
        }
        saveNodeCache()
    }

    /// Live peers previously discovered for `infoHash`, served before any network query so warm
    /// magnet resolutions start from known-reachable peers (mirrors bittorrent-dht's peer store).
    /// Confirmed-reachable peers come first, then freshly-announced live peers.
    public func cachedPeers(infoHash: Data) -> [PeerAddress] {
        lock.lock()
        defer { lock.unlock() }
        return (cachedPeersByHash[infoHash.hexString] ?? []).map(\.peer)
    }

    /// A `get_peers` token for `infoHash` (BEP 5): verifiable per-infohash, unguessable without
    /// the process secret, so only nodes we issued a token to can `announce_peer` to us.
    private func token(for infoHash: Data) -> Data {
        Data(Insecure.SHA1.hash(data: tokenSecret + infoHash))
    }

    /// Stores a peer that just announced itself for `infoHash` via `announce_peer`. These are
    /// the LIVE peers: a node that announces is, by definition, currently active in the swarm.
    /// They're inserted ahead of the older `get_peers` records so a fresh resolution tries them
    /// first (webtorrent's DHT node does exactly this with its peer store).
    private func cacheLivePeers(_ peers: [PeerAddress], for infoHash: Data) {
        guard !peers.isEmpty else { return }
        lock.lock()
        let key = infoHash.hexString
        var list = cachedPeersByHash[key] ?? []
        var seen = Set(list.map(\.peer))
        var inserted = false
        for peer in peers where seen.insert(peer).inserted {
            list.append(PeerCacheEntry(peer: peer, good: false))
            inserted = true
        }
        if inserted {
            let good = list.filter(\.good)
            let rest = list.filter { !$0.good }
            cachedPeersByHash[key] = Array((good + rest).prefix(500))
        }
        lock.unlock()
    }

    /// Iterative `get_peers` lookup (BEP 5, "closest node search"). Returns peer addresses
    /// collected from nodes that hold the torrent. Also populates the routing table. `onPeers`
    /// receives each batch of newly found peers as it lands (webtorrent streams every `get_peers`
    /// response), so the caller can feed them to a sweep without waiting for the full lookup.
    public func lookup(infoHash: Data, timeout: TimeInterval = 15, onPeers: (@Sendable ([PeerAddress]) async -> Void)? = nil) async throws -> [PeerAddress] {
        startListening()
        if table.count == 0 {
            // Spend part of the budget bootstrapping so we have nodes to query.
            try await bootstrap(timeout: min(timeout / 2, 8))
        }
        guard table.count > 0 else { throw DHTError.noBootstrapNodes }

        var peers = Set<PeerAddress>()
        var queried = Set<KRPCNodeInfo>()
        var candidates = table.closest(to: infoHash, count: k)
        let deadline = ContinuousClock.now + .seconds(timeout)

        // Run the full iterative closest-node search: nodes that hold the infohash are spread
        // across the table, so stopping at the first response that carries peers (the old
        // `if !peers.isEmpty { break }`) returned a handful of peers on sparse swarms. Keep
        // querying closer nodes — but once we have ~200 peers the sweep is adequately fed;
        // waiting out the full timeout only delays the (mostly-dead) peer drain.
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let batch = Array(candidates.filter { !queried.contains($0) }.prefix(16))
            guard !batch.isEmpty else { break }
            for node in batch {
                queried.insert(node)
            }
            let results = await withTaskGroup(of: (node: KRPCNodeInfo, reply: [String: BValue]?).self, returning: [(KRPCNodeInfo, [String: BValue]?)].self) { group in
                for node in batch {
                    group.addTask {
                        do {
                            return (node, try await self.query(.getPeers(id: self.nodeID, infoHash: infoHash), to: node))
                        } catch {
                            return (node, nil)
                        }
                    }
                }
                var collected: [(KRPCNodeInfo, [String: BValue]?)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            var newNodes: [KRPCNodeInfo] = []
            var newPeers: [PeerAddress] = []
            for (node, reply) in results {
                guard let reply else { continue }
                if let token = reply["token"]?.stringValue, let id = reply["id"]?.stringValue {
                    table.add(KRPCNodeInfo(id: id, host: node.host, port: node.port, token: token))
                }
                if let values = reply["values"]?.listValue {
                    for value in values {
                        if case .string(let compact) = value {
                            for peer in CompactPeer.parse(compact) where peers.insert(peer).inserted {
                                newPeers.append(peer)
                            }
                        }
                    }
                }
                if let nodes = reply["nodes"]?.stringValue {
                    for info in CompactNode.parse(nodes) where info.id != nodeID {
                        table.add(info)
                        newNodes.append(info)
                    }
                }
            }
            if !newPeers.isEmpty, let onPeers {
                await onPeers(newPeers)
            }
            let merged = Array(Set(candidates).union(newNodes))
                .sorted { isCloser($0.id, than: $1.id, to: infoHash) }
            candidates = Array(merged.prefix(k * 2))
            if peers.count >= 200 { break }
        }
        cachePeers(Array(peers), for: infoHash)
        saveNodeCache()
        return Array(peers)
    }

    func query(_ query: KRPCQuery, to node: KRPCNodeInfo) async throws -> [String: BValue] {
        // A 2-byte transaction id collides within minutes under sustained query load; the old
        // `pending[hex] = ...` would silently overwrite the earlier entry, orphaning its
        // continuation forever ("TASK CONTINUATION MISUSE ... leaked"). Use 4 bytes and re-roll
        // on collision so every registered continuation is guaranteed to be resumed.
        var transaction = Self.randomTransactionID()
        var packet = KRPCWire.encode(query: query, transaction: transaction)
        var hex = transaction.map { String(format: "%02x", $0) }.joined()
        while pendingContains(hex) {
            transaction = Self.randomTransactionID()
            packet = KRPCWire.encode(query: query, transaction: transaction)
            hex = transaction.map { String(format: "%02x", $0) }.joined()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let txnHex = hex
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(queryTimeout))
                if let pendingQuery = removePending(txnHex) {
                    pendingQuery.continuation.resume(throwing: DHTError.timeout)
                }
            }
            addPending(txnHex, PendingQuery(node: node, continuation: continuation, timeoutTask: timeoutTask))
            do {
                try socket.send(packet, to: node.host, port: node.port)
            } catch {
                timeoutTask.cancel()
                if let pendingQuery = removePending(txnHex) {
                    pendingQuery.continuation.resume(throwing: error)
                }
            }
        }
    }

    private func addPending(_ hex: String, _ pendingQuery: PendingQuery) {
        lock.lock()
        pending[hex] = pendingQuery
        lock.unlock()
    }

    private func pendingContains(_ hex: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending[hex] != nil
    }

    private func removePending(_ hex: String) -> PendingQuery? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: hex)
    }

    private func receiveLoop() {
        while true {
            if !isListeningNow() { return }
            do {
                guard let received = try socket.receiveFrom(timeout: 1) else { continue }
                handleResponse(received.data, fromHost: received.host, port: received.port)
            } catch {
                continue
            }
        }
    }

    private func isListeningNow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isListening
    }

    private func handleResponse(_ data: Data, fromHost host: String, port: UInt16) {
        guard let message = try? KRPCWire.decode(data) else { return }
        switch message {
        case .query(let transaction, let name, let args):
            // We are a DHT node, not just a client: answer inbound queries (BEP 5). This is what
            // lets us accumulate a LIVE peer store — nodes that lookup the infohash announce back
            // to us, and we cache those currently-active peers for fast resolution.
            handleQuery(name: name, args: args, transaction: transaction, fromHost: host, fromPort: port)
        case .response(let t, _), .error(let t, _, _):
            let hex = t.map { String(format: "%02x", $0) }.joined()
            guard let pendingQuery = removePending(hex) else { return }
            pendingQuery.timeoutTask.cancel()
            switch message {
            case .response(_, let reply):
                pendingQuery.continuation.resume(returning: reply)
            case .error(_, let code, let messageText):
                pendingQuery.continuation.resume(throwing: KRPCError.errorResponse(code: code, message: messageText))
            case .query:
                break
            }
        }
    }

    private func handleQuery(name: String, args: [String: BValue], transaction: Data, fromHost host: String, fromPort port: UInt16) {
        if let id = args["id"]?.stringValue, id.count == 20 {
            table.add(KRPCNodeInfo(id: id, host: host, port: port))
        }
        switch name {
        case "ping":
            sendResponse(transaction: transaction, reply: ["id": .string(nodeID)], to: host, port: port)
        case "find_node":
            guard let target = args["target"]?.stringValue, target.count == 20 else { return }
            let nodes = CompactNode.encode(table.closest(to: target, count: k))
            sendResponse(transaction: transaction, reply: ["id": .string(nodeID), "nodes": .string(nodes)], to: host, port: port)
        case "get_peers":
            guard let infoHash = args["info_hash"]?.stringValue, infoHash.count == 20 else { return }
            let peers = cachedPeers(infoHash: infoHash).prefix(50)
            var reply: [String: BValue] = [
                "id": .string(nodeID),
                "token": .string(token(for: infoHash)),
                "nodes": .string(CompactNode.encode(table.closest(to: infoHash, count: k))),
            ]
            if !peers.isEmpty {
                reply["values"] = .string(CompactPeer.encode(Array(peers)))
            }
            sendResponse(transaction: transaction, reply: reply, to: host, port: port)
        case "announce_peer":
            guard let infoHash = args["info_hash"]?.stringValue, infoHash.count == 20,
                  let token = args["token"]?.stringValue, token == self.token(for: infoHash) else {
                sendError(transaction: transaction, code: 203, message: "bad token", to: host, port: port)
                return
            }
            // Use the announced BT port, or the sender's UDP source port for implied_port/port 0.
            let announcedPort = args["port"]?.intValue
            let implied = (args["implied_port"]?.intValue ?? 0) != 0
            let peerPort = (implied || announcedPort == nil || announcedPort == 0) ? port : UInt16(clamping: announcedPort!)
            TorrentLog.log("DHT: announce_peer for \(infoHash.hexString.prefix(8)) from \(host):\(peerPort)")
            cacheLivePeers([PeerAddress(host: host, port: peerPort)], for: infoHash)
            sendResponse(transaction: transaction, reply: ["id": .string(nodeID)], to: host, port: port)
        default:
            break
        }
    }

    private func sendResponse(transaction: Data, reply: [String: BValue], to host: String, port: UInt16) {
        try? socket.send(KRPCWire.encodeResponse(transaction: transaction, reply: reply), to: host, port: port)
    }

    private func sendError(transaction: Data, code: Int, message: String, to host: String, port: UInt16) {
        try? socket.send(KRPCWire.encodeError(transaction: transaction, code: code, message: message), to: host, port: port)
    }

    /// Announces our BitTorrent listen port for `infoHash` (BEP 5): get a token from the closest
    /// nodes, then `announce_peer` to them so the swarm's DHT stores us as a peer. Participating
    /// this way is what makes the node (and its live peer store) real over time.
    public func announce(infoHash: Data, port: UInt16, timeout: TimeInterval = 10) async throws {
        startListening()
        if table.count == 0 {
            try await bootstrap(timeout: min(timeout / 2, 8))
        }
        guard table.count > 0 else { throw DHTError.noBootstrapNodes }

        let closeNodes = table.closest(to: infoHash, count: k)
        var tokenNodes = closeNodes.filter { $0.token != nil }
        let missing = closeNodes.filter { $0.token == nil }
        var fetchedTokens: [KRPCNodeInfo] = []
        await withTaskGroup(of: (KRPCNodeInfo, [String: BValue]?).self) { group in
            for node in missing.prefix(8) {
                group.addTask {
                    do {
                        return (node, try await self.query(.getPeers(id: self.nodeID, infoHash: infoHash), to: node))
                    } catch {
                        return (node, nil)
                    }
                }
            }
            for await (node, reply) in group {
                if let reply, let token = reply["token"]?.stringValue {
                    fetchedTokens.append(KRPCNodeInfo(id: node.id, host: node.host, port: node.port, token: token))
                }
            }
        }
        let announceTargets = Array((tokenNodes + fetchedTokens).prefix(k))
        TorrentLog.log("DHT: announce \(infoHash.hexString.prefix(8)) to \(announceTargets.count) nodes")
        await withTaskGroup(of: Void.self) { group in
            for node in announceTargets {
                guard let token = node.token else { continue }
                group.addTask {
                    _ = try? await self.query(.announcePeer(id: self.nodeID, infoHash: infoHash, port: port, token: token), to: node)
                }
            }
        }
        saveNodeCache()
    }

    private static func randomTransactionID() -> Data {
        Data((0..<4).map { _ in UInt8.random(in: 0...255) })
    }
}
