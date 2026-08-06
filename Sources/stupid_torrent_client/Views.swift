import SwiftUI
import AVKit
import AVFoundation
import TorrentCore
import Streaming

struct ContentView: View {
    @State private var store = TorrentStore()
    @State private var showAdd = false
    @State private var showCompleted = true

    private var downloadingItems: [TorrentItem] { store.items.filter { !$0.isComplete } }
    private var completedItems: [TorrentItem] { store.items.filter { $0.isComplete } }

    var body: some View {
        NavigationStack {
            List {
                if !downloadingItems.isEmpty {
                    Section {
                        ForEach(downloadingItems) { item in
                            row(item)
                        }
                    } header: {
                        Text("Downloading")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                }
                if !completedItems.isEmpty {
                    Section {
                        if showCompleted {
                            ForEach(completedItems) { item in
                                row(item)
                            }
                        }
                    } header: {
                        Button {
                            showCompleted.toggle()
                        } label: {
                            HStack {
                                Text("Completed")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tint)
                                    .rotationEffect(.degrees(showCompleted ? 90 : 0))
                                    .animation(.easeInOut(duration: 0.2), value: showCompleted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .textCase(nil)
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

    private func row(_ item: TorrentItem) -> some View {
        NavigationLink(value: item) {
            TorrentRow(item: item)
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                store.remove(item)
            }
        }
    }
}

struct TorrentRow: View {
    let item: TorrentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let status = item.status, status.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(relativeTime(item.addedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let status = item.status {
                if !status.isComplete {
                    HStack(spacing: 8) {
                        PieProgressView(progress: status.progress)
                            .frame(width: 16, height: 16)
                        Text("\(Int(status.progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    private var fileIndicesBySize: [Int] {
        item.metainfo.files.indices.sorted {
            item.metainfo.files[$0].length > item.metainfo.files[$1].length
        }
    }

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
                ForEach(fileIndicesBySize, id: \.self) { index in
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
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
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
        let loadingIndicator = UIActivityIndicatorView(style: .large)
        loadingIndicator.color = .white
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.startAnimating()
        let overlayView = controller.contentOverlayView ?? controller.view!
        overlayView.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
        ])
        player.play()
        Task { @MainActor [weak loadingIndicator, weak player] in
            while let player,
                  player.timeControlStatus != .playing,
                  player.currentItem?.status != .failed {
                try? await Task.sleep(for: .milliseconds(100))
            }
            loadingIndicator?.stopAnimating()
        }
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

struct PieProgressView: View {
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let rect = CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
            context.fill(Path(ellipseIn: rect), with: .color(.secondary.opacity(0.25)))
            let clamped = min(max(progress, 0), 1)
            guard clamped > 0 else { return }
            let pie = Path { path in
                path.move(to: center)
                path.addArc(
                    center: center,
                    radius: radius - 1,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + clamped * 360),
                    clockwise: false
                )
                path.closeSubpath()
            }
            context.fill(pie, with: .color(.blue))
        }
    }
}

func relativeTime(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 30 { return "\(days)d" }
    let months = days / 30
    if months < 12 { return "\(months)mo" }
    return "\(months / 12)y"
}
