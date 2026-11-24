import Foundation

public enum DHTNode {
    nonisolated(unsafe) private static var sharedClient: DHTClient?
    private static let lock = NSLock()

    public static func shared() -> DHTClient? {
        lock.withLock {
            if let sharedClient {
                return sharedClient
            }
            sharedClient = try? DHTClient(nodeID: persistedNodeID())
            return sharedClient
        }
    }

    public static func warmUp() {
        Task.detached(priority: .utility) {
            guard let dht = shared(), await dht.nodeCount == 0 else { return }
            await dht.bootstrap(timeout: 8)
        }
    }

    private static func persistedNodeID() -> Data {
        let url = DHTClient.cacheFile(named: "stupid-torrent-dht.nodeid")
        if let data = try? Data(contentsOf: url), data.count == 20 {
            return data
        }
        let id = DHTClient.randomNodeID()
        try? id.write(to: url)
        return id
    }
}
