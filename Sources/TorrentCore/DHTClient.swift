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
        loadNodeCache()
    }

    /// Cache location shared by all DHT clients so a warm routing table survives restarts
    /// (mirrors bittorrent-dht's "persist the DHT to disk between restarts" recommendation).
    public static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("stupid-torrent-dht.nodes")
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
        while ContinuousClock.now < deadline, !frontier.isEmpty {
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

    /// Iterative `get_peers` lookup (BEP 5, "closest node search"). Returns peer addresses
    /// collected from nodes that hold the torrent. Also populates the routing table.
    public func lookup(infoHash: Data, timeout: TimeInterval = 15) async throws -> [PeerAddress] {
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

        while ContinuousClock.now < deadline {
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
            for (node, reply) in results {
                guard let reply else { continue }
                if let token = reply["token"]?.stringValue, let id = reply["id"]?.stringValue {
                    table.add(KRPCNodeInfo(id: id, host: node.host, port: node.port, token: token))
                }
                if let values = reply["values"]?.listValue {
                    for value in values {
                        if case .string(let compact) = value {
                            for peer in CompactPeer.parse(compact) {
                                peers.insert(peer)
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
            let merged = Array(Set(candidates).union(newNodes))
                .sorted { isCloser($0.id, than: $1.id, to: infoHash) }
            candidates = Array(merged.prefix(k * 2))
            if !peers.isEmpty { break }
        }
        saveNodeCache()
        return Array(peers)
    }

    private func query(_ query: KRPCQuery, to node: KRPCNodeInfo) async throws -> [String: BValue] {
        let transaction = Self.randomTransactionID()
        let packet = KRPCWire.encode(query: query, transaction: transaction)
        let hex = transaction.map { String(format: "%02x", $0) }.joined()

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(queryTimeout))
                if let pendingQuery = removePending(hex) {
                    pendingQuery.continuation.resume(throwing: DHTError.timeout)
                }
            }
            addPending(hex, PendingQuery(node: node, continuation: continuation, timeoutTask: timeoutTask))
            do {
                try socket.send(packet, to: node.host, port: node.port)
            } catch {
                timeoutTask.cancel()
                if let pendingQuery = removePending(hex) {
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
        Data((0..<2).map { _ in UInt8.random(in: 0...255) })
    }
}
