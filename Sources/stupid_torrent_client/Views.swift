import SwiftUI
import AVKit
import AVFoundation
import TorrentCore
import Streaming

struct ContentView: View {
    @State private var store = TorrentStore()
    @State private var showAdd = false
    @State private var showCompleted = true
    @Environment(\.scenePhase) private var scenePhase

    private var downloadingItems: [TorrentItem] { store.items.filter { !$0.isComplete } }
    private var completedItems: [TorrentItem] { store.items.filter { $0.isComplete } }

    /// True while anything needs the network: resolving a magnet, or a torrent in the `.downloading`
    /// state (paused/complete/error do not keep the screen awake).
    private var shouldKeepAwake: Bool {
        !store.resolvingItems.isEmpty || store.items.contains { $0.status?.state == .downloading }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty && store.resolvingItems.isEmpty {
                    ContentUnavailableView(
                        "No Torrents",
                        systemImage: "arrow.down.circle",
                        description: Text("Add a magnet link or a .torrent file to start downloading.")
                    )
                } else {
                    List {
                        if !store.resolvingItems.isEmpty || !downloadingItems.isEmpty {
                            Section {
                                ForEach(store.resolvingItems) { item in
                                    ResolvingTorrentRow(item: item)
                                }
                                ForEach(downloadingItems) { item in
                                    row(item)
                                }
                            } header: {
                                Text("In Progress")
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
                }
            }
            .navigationDestination(for: TorrentItem.self) { item in
                TorrentDetailView(item: item, store: store)
            }
            #if os(iOS)
            .fullScreenCover(item: $store.pendingPlayback) { request in
                switch request.kind {
                case .avPlayer:
                    PlayerView(session: TorrentStreamSession(torrent: request.torrent, fileIndex: request.fileIndex))
                case .none:
                    EmptyView()
                }
            }
            #endif
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
                    switch source {
                    case .magnet(let string):
                        try store.addMagnet(string)
                    case .file(let url):
                        try store.addFile(url)
                    }
                }
            }
            .alert("Could Not Add Torrent", isPresented: Binding(
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
        .onChange(of: scenePhase) { _, phase in
            // Re-apply on every phase change so a resume from background restores the right state.
            IdleTimer.update(isDownloading: phase == .active && shouldKeepAwake)
        }
        .onChange(of: shouldKeepAwake) { _, downloading in
            IdleTimer.update(isDownloading: downloading)
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "magnet" else { return }
            do {
                try store.addMagnet(url.absoluteString)
            } catch {
                store.addError = error.localizedDescription
            }
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
        .swipeActions(edge: .leading) {
            Button(item.isPaused ? "Resume" : "Pause") {
                store.togglePause(item)
            }
            .tint(item.isPaused ? .blue : .orange)
        }
    }
}

struct ResolvingTorrentRow: View {
    let item: ResolvingTorrentItem

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
            Text(item.name)
                .font(.body)
                .lineLimit(1)
            Spacer()
            Text(relativeTime(item.addedAt))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct TorrentRow: View {
    let item: TorrentItem

    var body: some View {
        HStack(spacing: 8) {
            if let status = item.status {
                if status.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else if item.isPaused {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.secondary)
                } else {
                    PieProgressView(progress: status.progress)
                        .frame(width: 20, height: 20)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            }
            Text(item.name)
                .font(.body)
                .lineLimit(1)
            Spacer()
            Text(item.isPaused ? "Paused" : (eta ?? relativeTime(item.addedAt)))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var eta: String? {
        guard let status = item.status,
              let seconds = remainingSeconds(status, metainfo: item.metainfo) else { return nil }
        return "ETA \(durationString(seconds))"
    }
}

enum AddSource {
    case magnet(String)
    case file(URL)
}

struct AddTorrentView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (AddSource) throws -> Void

    @State private var magnet = ""
    @State private var showingImporter = false
    @State private var addError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Magnet link") {
                    TextField("magnet:?xt=urn:btih:…", text: $magnet)
                        .lineLimit(1)
                        .autocorrectionDisabled()
                    Button {
                        add(.magnet(magnet))
                    } label: {
                        Text("Add")
                    }
                    .disabled(magnet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Torrent file") {
                    Button("Choose .torrent…") {
                        showingImporter = true
                    }
                }
            }
            .navigationTitle("Add torrent")
            .onAppear {
                if magnet.isEmpty, let clipboard = clipboardString(), (try? MagnetLinkParser.parse(clipboard)) != nil {
                    magnet = String(clipboard.drop(while: \.isWhitespace))
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result {
                    add(.file(url))
                }
            }
            .alert("Could Not Add Torrent", isPresented: Binding(
                get: { addError != nil },
                set: { if !$0 { addError = nil } }
            )) {
                Button("OK", role: .cancel) { addError = nil }
            } message: {
                Text(addError ?? "")
            }
        }
    }

    private func add(_ source: AddSource) {
        do {
            try onAdd(source)
            dismiss()
        } catch {
            addError = error.localizedDescription
        }
    }
}

struct TorrentDetailView: View {
    let item: TorrentItem
    let store: TorrentStore

    // macOS keeps the player presentation local; iOS presents from ContentView via
    // `store.pendingPlayback` because this view is recreated on every status tick for a
    // downloading torrent, which would reset local `@State` and break the cover.
    #if !os(iOS)
    @State private var streamSession: TorrentStreamSession?
    @State private var showPlayer = false
    #endif

    private var fileIndicesBySize: [Int] {
        item.metainfo.files.indices.sorted {
            item.metainfo.files[$0].length > item.metainfo.files[$1].length
        }
    }

    var body: some View {
        List {
            if let status = item.status, !status.isComplete {
                Section("Status") {
                    LabeledContent("Progress", value: item.isPaused ? "\(Int(status.progress * 100))% (Paused)" : "\(Int(status.progress * 100))%")
                    LabeledContent("Pieces", value: "\(status.verifiedCount)/\(status.pieceCount)")
                    if !item.isPaused {
                        LabeledContent("Download", value: byteRateString(status.downloadRate))
                        LabeledContent("ETA", value: remainingSeconds(status, metainfo: item.metainfo).map(durationString) ?? "-")
                        LabeledContent("Peers", value: "\(status.peers) (\(status.seeds) seeds)")
                    }
                }
            }
            Section("Files") {
                ForEach(fileIndicesBySize, id: \.self) { index in
                    let file = item.metainfo.files[index]
                    let playbackKind = Torrent.playbackKind(forFileNamed: file.name)
                    let isStreamable = playbackKind != .none
                    let isPlaybackAvailable = item.isPlaybackAvailable(fileIndex: index)
                    Button {
                        if isPlaybackAvailable {
                            openPlayer(fileIndex: index, kind: playbackKind)
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
                    .disabled(!isPlaybackAvailable)
                    .task {
                        item.preparePlaybackAvailability(fileIndex: index)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
            }
        }
        .navigationTitle(item.name)
        .toolbar {
            TorrentDetailMenu(item: item, store: store)
        }
        #if !os(iOS)
        .sheet(isPresented: $showPlayer) {
            if let streamSession {
                PlayerView(session: streamSession)
            }
        }
        #endif
    }

    private func openPlayer(fileIndex: Int, kind: Torrent.PlaybackKind) {
        #if os(iOS)
        store.pendingPlayback = PlaybackRequest(torrent: item.torrent, fileIndex: fileIndex, kind: kind)
        #else
        streamSession = TorrentStreamSession(torrent: item.torrent, fileIndex: fileIndex)
        showPlayer = true
        #endif
    }
}

/// The detail view's kebab menu. Reads only `TorrentItem`'s change-guarded pause flags (not the
/// 1s-churning `status`), so it doesn't rebuild every tick and cause the toolbar brightness pulse.
private struct TorrentDetailMenu: View {
    let item: TorrentItem
    let store: TorrentStore

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        Menu {
            if item.canPause {
                Button {
                    store.togglePause(item)
                } label: {
                    Label(item.isPaused ? "Resume" : "Pause", systemImage: item.isPaused ? "play" : "pause")
                }
            }
            Button {
                copyMagnet()
            } label: {
                Label("Copy Magnet", systemImage: "link")
            }
            Divider()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .confirmationDialog("Delete \"\(item.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.remove(item)
                dismiss()
            }
        }
    }

    private func copyMagnet() {
        let magnet = magnetLink(item.metainfo)
        #if os(iOS)
        UIPasteboard.general.string = magnet
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(magnet, forType: .string)
        #endif
    }
}

struct PlayerView: View {
    let session: TorrentStreamSession
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                #if os(iOS)
                AVPlayerControllerRepresentable(player: player)
                    .ignoresSafeArea()
                #else
                VideoPlayerView(player: player)
                #endif
            } else {
                ProgressView()
                    .task {
                        let preparedPlayer = await session.makePlayer()
                        guard !Task.isCancelled else {
                            preparedPlayer.pause()
                            return
                        }
                        player = preparedPlayer
                    }
            }
        }
        .onAppear {
            #if os(iOS)
            OrientationLock.playerPresented = true
            #endif
        }
        .onDisappear {
            #if os(iOS)
            OrientationLock.playerPresented = false
            #endif
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            session.stop()
        }
    }
}

#if os(iOS)
struct AVPlayerControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsPlaybackControls = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        configureAudioSession()
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
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
    let player: AVPlayer

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                player.play()
            }
    }
}
#endif

func clipboardString() -> String? {
    #if os(iOS)
    return UIPasteboard.general.string
    #else
    return NSPasteboard.general.string(forType: .string)
    #endif
}

func magnetLink(_ metainfo: Metainfo) -> String {
    var parts = ["xt=urn:btih:\(metainfo.infoHash.hexString)"]
    if let dn = metainfo.displayName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        parts.append("dn=\(dn)")
    }
    for tracker in metainfo.flattenedTrackers {
        if let tr = tracker.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            parts.append("tr=\(tr)")
        }
    }
    return "magnet:?" + parts.joined(separator: "&")
}

func byteString(_ bytes: Double) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB", bytes / 1_000_000_000) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.1f KB", bytes / 1_000) }
    return "\(Int(bytes)) B"
}

func byteRateString(_ bytesPerSecond: Double) -> String {
    "\(byteString(bytesPerSecond))/s"
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

func remainingSeconds(_ status: TorrentStatus, metainfo: Metainfo) -> Double? {
    guard !status.isComplete, status.downloadRate > 0 else { return nil }
    let total = metainfo.files.reduce(Int64(0)) { $0 + Int64($1.length) }
    let remaining = Double(total) * (1 - status.progress)
    guard remaining > 0 else { return nil }
    return remaining / status.downloadRate
}

func durationString(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "<1m" }
    let minutes = s / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 30 { return "\(days)d" }
    let months = days / 30
    if months < 12 { return "\(months)mo" }
    return "\(months / 12)y"
}
