import Foundation

struct PeerPool {
    static let reconnectBackoff: [Duration] = [.seconds(1), .seconds(5), .seconds(15)]
    static let strikesBeforeBan = 2

    let capacity: Int
    private(set) var queue: [PeerAddress] = []
    private(set) var dialing: Set<PeerAddress> = []
    private(set) var banned: Set<PeerAddress> = []
    private var waiting: Set<PeerAddress> = []
    private var attempts: [PeerAddress: Int] = [:]
    private var strikes: [PeerAddress: Int] = [:]

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func enqueue(_ address: PeerAddress, isConnected: Bool) {
        guard !isConnected, !banned.contains(address), !dialing.contains(address), waiting.insert(address).inserted else { return }
        queue.append(address)
    }

    mutating func nextDial(connectedCount: Int) -> PeerAddress? {
        while dialing.count + connectedCount < capacity, !queue.isEmpty {
            let address = queue.removeFirst()
            waiting.remove(address)
            guard !banned.contains(address) else { continue }
            dialing.insert(address)
            return address
        }
        return nil
    }

    mutating func dialEnded(_ address: PeerAddress) {
        dialing.remove(address)
    }

    mutating func reconnectDelay(for address: PeerAddress, handshook: Bool) -> Duration? {
        if handshook {
            attempts.removeValue(forKey: address)
        }
        guard !banned.contains(address) else { return nil }
        let count = attempts[address] ?? 0
        guard count < Self.reconnectBackoff.count else {
            attempts.removeValue(forKey: address)
            return nil
        }
        attempts[address] = count + 1
        guard !dialing.contains(address), waiting.insert(address).inserted else { return nil }
        return Self.reconnectBackoff[count]
    }

    mutating func reconnect(_ address: PeerAddress) {
        guard waiting.contains(address), !queue.contains(address), !banned.contains(address) else { return }
        queue.append(address)
    }

    mutating func strike(_ address: PeerAddress) -> Bool {
        let count = (strikes[address] ?? 0) + 1
        strikes[address] = count
        guard count >= Self.strikesBeforeBan else { return false }
        banned.insert(address)
        return true
    }

    mutating func reset() {
        queue.removeAll()
        waiting.removeAll()
        attempts.removeAll()
    }
}
