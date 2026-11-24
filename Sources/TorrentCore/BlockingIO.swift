import Foundation

public enum BlockingIO {
    public static func run<T: Sendable>(
        name: String, _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            spawn(name: name) {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    public static func spawn(name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.start()
    }
}
