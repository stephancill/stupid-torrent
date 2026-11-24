import SwiftUI

struct Loadable<Value> {
    var value: Value?
    var isLoading = false
    var error: String?
}

@MainActor
func load<Value>(_ state: Binding<Loadable<Value>>, operation: () async throws -> Value) async {
    state.wrappedValue.isLoading = true
    state.wrappedValue.error = nil
    do {
        let value = try await operation()
        guard !Task.isCancelled else { return }
        state.wrappedValue = Loadable(value: value)
    } catch {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        state.wrappedValue = Loadable(error: error.localizedDescription)
    }
}

struct LoadableContent<Value, Content: View>: View {
    let state: Loadable<Value>
    let failureTitle: String
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        if let value = state.value {
            content(value)
        } else if let error = state.error {
            ContentUnavailableView {
                Label(failureTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    Task { await retry() }
                }
            }
        } else {
            LoadingView()
        }
    }
}

struct LoadingView: View {
    var body: some View {
        ProgressView()
            #if !os(tvOS)
            .controlSize(.large)
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
