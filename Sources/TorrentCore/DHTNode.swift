import Foundation

/// The app-lifetime DHT node: one stable `DHTClient` (persisted node ID, one live UDP socket)
/// shared by every torrent's `dhtLoop` and by magnet bootstrapping. A node's value comes from
/// being a *stable* participant — a fresh identity every cycle (the old per-`dhtLoop` client)
/// means nodes that learned us query a dead identity, and we never build a durable position. One
/// persistent node also means the live peer store keeps accumulating for the whole session and is
/// served to magnet resolutions, not just downloads.
public enum DHTNode {
    nonisolated(unsafe) private static var sharedClient: DHTClient?
    private static let lock = NSLock()

    /// Returns the shared node, creating it on first use with the persisted node identity and
    /// starting its receive loop. Safe to call from any task (Torrent actors, bootstrapper).
    public static func shared() -> DHTClient? {
        lock.lock()
        defer { lock.unlock() }
        if let sharedClient {
            return sharedClient
        }
        guard let client = try? DHTClient(nodeID: persistedNodeID()) else { return nil }
        client.startListening()
        sharedClient = client
        return client
    }

    /// Tears the shared node down (stops its socket/threads). The app keeps the node for its whole
    /// foreground lifetime; this is for tests and explicit shutdown.
    public static func stop() {
        lock.lock()
        defer { lock.unlock() }
        sharedClient?.stop()
        sharedClient = nil
    }

    private static func persistedNodeID() -> Data {
        let url = DHTClient.defaultNodeIDURL()
        if let data = try? Data(contentsOf: url), data.count == 20 {
            return data
        }
        let id = DHTClient.randomNodeID()
        try? id.write(to: url)
        return id
    }
}
