import Foundation

public struct TimeoutError: Error, Sendable {}

func withTimeout<T: Sendable>(
    _ duration: Duration,
    onCancel: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await withTaskCancellationHandler(operation: operation, onCancel: onCancel)
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
