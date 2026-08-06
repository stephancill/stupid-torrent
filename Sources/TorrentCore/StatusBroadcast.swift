import Foundation

/// Multi-subscriber, current-value stream. Every subscriber receives the current value on
/// subscribe, then all subsequent publishes. Used to fan out torrent status to the UI and
/// streaming controller without a single-subscriber `AsyncStream`.
public actor StatusBroadcast<Value: Sendable> {
    private var currentValue: Value
    private var subscribers: [UUID: AsyncStream<Value>.Continuation] = [:]

    public init(_ initial: Value) {
        currentValue = initial
    }

    public var value: Value { currentValue }

    public func publish(_ value: Value) {
        currentValue = value
        for continuation in subscribers.values {
            continuation.yield(value)
        }
    }

    public func subscribe() -> AsyncStream<Value> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
            continuation.yield(currentValue)
        }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
