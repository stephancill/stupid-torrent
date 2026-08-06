import SwiftUI
import AVKit
import AVFoundation
import TorrentCore
import Streaming

struct ContentView: View {
    @State private var store = TorrentStore()
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List(store.items) { item in
                NavigationLink(value: item) {
                    TorrentRow(item: item)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        store.remove(item)
                    }
                }
            }
            .navigationDestination(for: TorrentItem.self) { item in
                TorrentDetailView(item: item)
            }
            .navigationTitle("Torrents")
            .toolbar {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(isPresented: $showAdd) {
                AddTorrentView { source in
                    Task {
                        switch source {
                        case .magnet(let string):
                            await store.addMagnet(string)
                        case .file(let url):
                            await store.addFile(url)
                        }
                        showAdd = false
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { store.addError != nil },
                set: { if !$0 { store.addError = nil } }
            )) {
                Button("OK", role: .cancel) { store.addError = nil }
            } message: {
                Text(store.addError ?? "")
            }
        }
        .onAppear {
            store.restore()
        }
    }
}

struct TorrentRow: View {
    let item: TorrentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .font(.headline)
                .lineLimit(1)
            if let status = item.status {
                if !status.isComplete {
                    ProgressView(value: status.progress)
                    HStack {
                        Text("\(Int(status.progress * 100))%")
                        Spacer()
                        Text("↓ \(byteString(status.downloadRate)) · ↑ \(byteString(status.uploadRate))")
                        Text("\(status.peers) peers")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("starting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

enum AddSource {
    case magnet(String)
    case file(URL)
}

struct AddTorrentView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (AddSource) -> Void

    @State private var magnet = ""
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Magnet link") {
                    TextField("magnet:?xt=urn:btih:…", text: $magnet, axis: .vertical)
                        .autocorrectionDisabled()
                    Button("Add") {
                        onAdd(.magnet(magnet))
                        dismiss()
                    }
                    .disabled(magnet.isEmpty)
                }
                Section("Torrent file") {
                    Button("Choose .torrent…") {
                        showingImporter = true
                    }
                }
            }
            .navigationTitle("Add torrent")
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result {
                    onAdd(.file(url))
                }
            }
        }
    }
}

struct TorrentDetailView: View {
    let item: TorrentItem

    @State private var streamSession: TorrentStreamSession?
    @State private var showPlayer = false

    var body: some View {
        List {
            if let status = item.status, !status.isComplete {
                Section("Status") {
                    LabeledContent("Progress", value: "\(Int(status.progress * 100))%")
                    LabeledContent("Pieces", value: "\(status.verifiedCount)/\(status.pieceCount)")
                    LabeledContent("Download", value: byteString(status.downloadRate))
                    LabeledContent("Upload", value: byteString(status.uploadRate))
                    LabeledContent("Peers", value: "\(status.peers) (\(status.seeds) seeds)")
                }
            }
            Section("Files") {
                ForEach(item.metainfo.files.indices, id: \.self) { index in
                    let file = item.metainfo.files[index]
                    let isStreamable = Torrent.contentType(forFileNamed: file.name) != nil
                    Button {
                        if isStreamable {
                            openPlayer(fileIndex: index)
                        }
                    } label: {
                        HStack {
                            if isStreamable {
                                Image(systemName: "play.circle")
                            }
                            Text(file.name)
                                .lineLimit(1)
                            Spacer()
                            Text(byteString(Double(file.length)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!isStreamable)
                }
            }
        }
        .navigationTitle(item.name)
        #if os(iOS)
        .fullScreenCover(isPresented: $showPlayer) {
            if let streamSession {
                PlayerView(session: streamSession)
            }
        }
        #else
        .sheet(isPresented: $showPlayer) {
            if let streamSession {
                PlayerView(session: streamSession)
            }
        }
        #endif
    }

    private func openPlayer(fileIndex: Int) {
        streamSession = TorrentStreamSession(torrent: item.torrent, fileIndex: fileIndex)
        showPlayer = true
    }
}

struct PlayerView: View {
    let session: TorrentStreamSession

    var body: some View {
        #if os(iOS)
        AVPlayerControllerRepresentable(session: session)
            .ignoresSafeArea()
        #else
        VideoPlayerView(session: session)
        #endif
    }
}

#if os(iOS)
struct AVPlayerControllerRepresentable: UIViewControllerRepresentable {
    let session: TorrentStreamSession

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        configureAudioSession()
        let player = AVPlayer(playerItem: AVPlayerItem(asset: session.asset))
        let controller = AVPlayerViewController()
        controller.player = player
        // System PiP button appears automatically when supported and content allows it.
        controller.allowsPictureInPicturePlayback = true
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback)
        try? audioSession.setActive(true)
    }
}
#else
struct VideoPlayerView: View {
    let session: TorrentStreamSession
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: session.asset))
                player = newPlayer
                newPlayer.play()
            }
    }
}
#endif

func byteString(_ bytes: Double) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB", bytes / 1_000_000_000) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.1f KB", bytes / 1_000) }
    return "\(Int(bytes)) B"
}
