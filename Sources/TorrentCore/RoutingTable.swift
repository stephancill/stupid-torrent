import Foundation

public struct KRPCNodeInfo: Hashable, Sendable {
    public let id: Data
    public let host: String
    public let port: UInt16

    public init(id: Data, host: String, port: UInt16) {
        self.id = id
        self.host = host
        self.port = port
    }

    var address: PeerAddress {
        PeerAddress(host: host, port: port)
    }
}

struct RoutingTable: Sendable {
    let localID: Data
    private let k: Int
    private var buckets: [[KRPCNodeInfo]]

    init(localID: Data, k: Int = 20) {
        self.localID = localID
        self.k = k
        buckets = Array(repeating: [], count: localID.count * 8 + 1)
    }

    var count: Int {
        buckets.reduce(0) { $0 + $1.count }
    }

    var allNodes: [KRPCNodeInfo] {
        buckets.flatMap { $0 }
    }

    mutating func add(_ node: KRPCNodeInfo) {
        guard node.id.count == localID.count else { return }
        let index = bucketIndex(for: node.id)
        if let existing = buckets[index].firstIndex(where: { $0.id == node.id }) {
            buckets[index][existing] = node
            return
        }
        if buckets[index].count >= k {
            buckets[index].removeFirst()
        }
        buckets[index].append(node)
    }

    func closest(to target: Data, count: Int) -> [KRPCNodeInfo] {
        Array(allNodes.sorted { isCloser($0.id, than: $1.id, to: target) }.prefix(count))
    }

    private func bucketIndex(for id: Data) -> Int {
        var zeros = 0
        for (a, b) in zip(id, localID) {
            let byte = a ^ b
            zeros += byte.leadingZeroBitCount
            if byte != 0 { break }
        }
        return zeros
    }
}

func isCloser(_ a: Data, than b: Data, to target: Data) -> Bool {
    for ((ai, bi), ti) in zip(zip(a, b), target) {
        let da = ai ^ ti
        let db = bi ^ ti
        if da != db { return da < db }
    }
    return false
}
