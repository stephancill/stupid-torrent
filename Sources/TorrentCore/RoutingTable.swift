import Foundation

/// A node in the DHT overlay. `id` is the 20-byte node id; `host`/`port` are its UDP address.
public struct KRPCNodeInfo: Hashable, Sendable {
    public let id: Data
    public let host: String
    public let port: UInt16
    /// Token returned by a `get_peers` response, needed to `announce_peer` back.
    public var token: Data?

    public init(id: Data, host: String, port: UInt16, token: Data? = nil) {
        self.id = id
        self.host = host
        self.port = port
        self.token = token
    }
}

/// A simplified Kademlia routing table: buckets keyed by the common-prefix length of the XOR
/// distance to our own node id. Each bucket holds up to `k` nodes; overflow evicts the oldest
/// (stale-first) entry, matching bittorrent-dht's practical behavior without ping-swapping.
public final class RoutingTable: @unchecked Sendable {
    public let localID: Data
    public let k: Int
    private var buckets: [[KRPCNodeInfo]]
    private let lock = NSLock()

    public init(localID: Data, k: Int = 20) {
        self.localID = localID
        self.k = k
        // common prefix length of XOR distance to self ranges 0...160 (inclusive)
        self.buckets = Array(repeating: [], count: 161)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buckets.reduce(0) { $0 + $1.count }
    }

    public var allNodes: [KRPCNodeInfo] {
        lock.lock()
        defer { lock.unlock() }
        return buckets.flatMap { $0 }
    }

    @discardableResult
    public func add(_ node: KRPCNodeInfo) -> Bool {
        guard node.id.count == localID.count else { return false }
        lock.lock()
        defer { lock.unlock() }
        let index = bucketIndex(for: node.id)
        if let existing = buckets[index].firstIndex(where: { $0.id == node.id }) {
            buckets[index][existing] = node
            return true
        }
        if buckets[index].count < k {
            buckets[index].append(node)
            return true
        }
        // Full bucket: replace the least-recently-seen entry.
        buckets[index].removeFirst()
        buckets[index].append(node)
        return true
    }

    public func remove(id: Data) {
        lock.lock()
        defer { lock.unlock() }
        let index = bucketIndex(for: id)
        buckets[index].removeAll { $0.id == id }
    }

    /// The `k` nodes in the table closest to `target` by XOR distance.
    public func closest(to target: Data, count: Int = 20) -> [KRPCNodeInfo] {
        lock.lock()
        defer { lock.unlock() }
        return buckets.flatMap { $0 }
            .sorted { isCloser($0.id, than: $1.id, to: target) }
            .prefix(count)
            .map { $0 }
    }

    private func bucketIndex(for id: Data) -> Int {
        let xor = xor(id, localID)
        // count leading zero bytes/bits of the XOR
        var zeros = 0
        for byte in xor {
            if byte == 0 {
                zeros += 8
            } else {
                zeros += byte.leadingZeroBitCount
                break
            }
        }
        return min(zeros, 160)
    }
}

/// True if `a` is XOR-closer to `target` than `b` (lexicographic byte comparison).
func isCloser(_ a: Data, than b: Data, to target: Data) -> Bool {
    for ((ai, bi), ti) in zip(zip(a, b), target) {
        let da = ai ^ ti
        let db = bi ^ ti
        if da != db { return da < db }
    }
    return false
}

private func xor(_ a: Data, _ b: Data) -> [UInt8] {
    zip(a, b).map { $0 ^ $1 }
}
