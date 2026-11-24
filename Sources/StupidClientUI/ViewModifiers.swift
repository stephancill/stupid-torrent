import StupidClientCore
import SwiftUI
import TorrentCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension View {
    public func errorAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }

    public func keepsScreenAwake(while needed: Bool) -> some View {
        modifier(IdleTimerModifier(needed: needed))
    }
}

private struct IdleTimerModifier: ViewModifier {
    let needed: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: needed && scenePhase == .active, initial: true) { _, keepAwake in
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = keepAwake
            TorrentLog.log("idle timer \(keepAwake ? "disabled" : "enabled")")
            #endif
        }
    }
}

#if !os(tvOS)
public func copyToClipboard(_ string: String) {
    #if os(iOS)
    UIPasteboard.general.string = string
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #endif
}
#endif
