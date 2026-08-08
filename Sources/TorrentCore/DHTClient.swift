import Foundation
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

    public init(nodeID: Data = DHTClient.randomNodeID(), cacheURL: URL? = nil) throws {
        self.nodeID = nodeID
        self.socket = try UDPSocket()
        self.table = RoutingTable(localID: nodeID, k: k)
        self.nodeCacheURL = cacheURL ?? Self.defaultCacheURL()
        self.peerCacheURL = Self.defaultPeerCacheURL()
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

    public func startListening() {
        lock.lock()
        if isListening {
            lock.unlock()
            return
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
    /// Confirmed-reachable peers come first.
    public func cachedPeers(infoHash: Data) -> [PeerAddress] {
        lock.lock()
        defer { lock.unlock() }
        return (cachedPeersByHash[infoHash.hexString] ?? []).map(\.peer)
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

    private func query(_ query: KRPCQuery, to node: KRPCNodeInfo) async throws -> [String: BValue] {
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
                guard let data = try socket.receive(timeout: 1) else { continue }
                handleResponse(data)
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

    private func handleResponse(_ data: Data) {
        guard let message = try? KRPCWire.decode(data) else { return }
        let transaction: Data
        switch message {
        case .response(let t, _), .error(let t, _, _):
            transaction = t
        case .query:
            return
        }
        let hex = transaction.map { String(format: "%02x", $0) }.joined()
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

    private static func randomTransactionID() -> Data {
        Data((0..<4).map { _ in UInt8.random(in: 0...255) })
    }
}
