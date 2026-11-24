import StupidClientCore
import SwiftUI

extension View {
    public func deleteTorrentAlert(item: Binding<TorrentItem?>, onDelete: @escaping (TorrentItem) -> Void) -> some View {
        alert(
            "Delete \u{201C}\(item.wrappedValue?.name ?? "")\u{201D}?",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            presenting: item.wrappedValue
        ) { pending in
            Button("Cancel", role: .cancel) {}
            Button("Delete Torrent", role: .destructive) {
                onDelete(pending)
            }
        } message: { _ in
            Text("This stops the torrent and deletes its downloaded files from this device.")
        }
    }
}
