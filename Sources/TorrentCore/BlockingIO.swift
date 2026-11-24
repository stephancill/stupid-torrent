import Foundation

/// Runs blocking socket work on a dedicated `Thread`, never on Swift's cooperative pool. The
/// pool has one thread per CPU core: on a 2-core device (Apple TV HD) a couple of blocking
/// receives on it starve every actor and the whole engine freezes.
enum BlockingIO {
    static func run<T: Sendable>(
        name: String, _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try operation() })
            }
            thread.name = name
            thread.start()
        }
    }
}
