import AVFoundation
import AVKit
import Streaming
import StupidClientCore
import StupidClientUI
import SwiftUI
import TorrentCore
import UIKit

/// Big Buck Bunny (see docs/planning.md): a known-good public torrent for trying playback.
private let sampleMagnet =
    "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce"

/// Open-licensed Blender films for testing streaming from scratch.
private let otherSamples: [(name: String, magnet: String)] = [
    ("Sintel", "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Sintel&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce"),
    ("Tears of Steel", "magnet:?xt=urn:btih:209c8226b299b308beaf2b9cd3fb49212dbd13ec&dn=Tears+of+Steel&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce"),
    ("Cosmos Laundromat", "magnet:?xt=urn:btih:c9e15763f722f23e98a29decdfae341b98d53056&dn=Cosmos+Laundromat&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce"),
]

struct TVContentView: View {
    @State private var store = TorrentStore()
    @State private var showAdd = false
    @State private var path: [TorrentItem] = []
    @State private var selectedTab = TVTab.library
    @Environment(\.scenePhase) private var scenePhase

    private var isBusy: Bool {
        !store.resolvingItems.isEmpty || store.items.contains { $0.status?.state == .downloading }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Torrents", systemImage: "arrow.down.circle", value: .library) {
                NavigationStack(path: $path) {
                    TVLibraryView(store: store, showAdd: $showAdd)
                        .navigationDestination(for: TorrentItem.self) { item in
                            TVTorrentDetailView(item: item, store: store)
                        }
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
                TorrentSearchView(store: store) { item in
                    TVTorrentDetailView(item: item, store: store)
                }
            }
        }
        .fullScreenCover(item: $store.pendingPlayback) { request in
            TVPlayerView(
                session: TorrentStreamSession(torrent: request.torrent, fileIndex: request.fileIndex),
                store: store,
                torrent: request.torrent,
                fileIndex: request.fileIndex
            )
        }
        .alert("Could Not Add Torrent", isPresented: Binding(
            get: { store.addError != nil },
            set: { if !$0 { store.addError = nil } }
        )) {
            Button("OK", role: .cancel) { store.addError = nil }
        } message: {
            Text(store.addError ?? "")
        }
        .onAppear {
            store.restore()
            #if DEBUG
            applyDebugLaunchArguments()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active && isBusy
        }
        .onChange(of: isBusy) { _, busy in
            UIApplication.shared.isIdleTimerDisabled = busy
        }
    }
}

enum TVTab: Hashable {
    case library
    case search
}

struct TVLibraryView: View {
    let store: TorrentStore
    @Binding var showAdd: Bool

    private var downloadingItems: [TorrentItem] { store.items.filter { !$0.isComplete } }
    private var completedItems: [TorrentItem] { store.items.filter { $0.isComplete } }

    var body: some View {
        content
            .navigationDestination(isPresented: $showAdd) {
                TVAddTorrentView { magnet in
                    try store.addMagnet(magnet)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty && store.resolvingItems.isEmpty {
            ContentUnavailableView {
                Label("No Torrents", systemImage: "arrow.down.circle")
            } description: {
                Text("Find a movie or show in Search, or add a magnet link.")
            } actions: {
                Button("Add Magnet Link") {
                    showAdd = true
                }
            }
        } else {
            List {
                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Magnet Link", systemImage: "plus")
                    }
                }
                if !store.resolvingItems.isEmpty || !downloadingItems.isEmpty {
                    Section("In Progress") {
                        ForEach(store.resolvingItems) { item in
                            HStack(spacing: 24) {
                                Text(item.name)
                                    .lineLimit(1)
                                Spacer()
                                ProgressView()
                            }
                        }
                        ForEach(downloadingItems) { item in
                            NavigationLink(value: item) {
                                TVTorrentRow(item: item)
                            }
                        }
                    }
                }
                if !completedItems.isEmpty {
                    Section("Completed") {
                        ForEach(completedItems) { item in
                            NavigationLink(value: item) {
                                TVTorrentRow(item: item)
                            }
                        }
                    }
                }
            }
        }
    }
}

#if DEBUG
extension TVContentView {
    /// Opens screens from launch arguments so the simulator can be screenshotted without remote
    /// input: `-SearchQuery <text>` (opens Search; see StupidClientUI for `-SearchOpenFirst`), `-ShowAdd`, `-AddSample` (adds Big Buck Bunny), `-OpenFirst` (opens the first
    /// torrent once it exists), `-PlayFirst` (plays its largest file).
    fileprivate func applyDebugLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-SearchQuery") {
            selectedTab = .search
        }
        if arguments.contains("-ShowAdd") {
            showAdd = true
        }
        if arguments.contains("-AddSample") {
            try? store.addMagnet(sampleMagnet)
        }
        if arguments.contains("-PlayFirst") {
            Task {
                for _ in 0..<120 {
                    if let first = store.items.first,
                       let index = first.metainfo.files.indices.max(by: {
                           first.metainfo.files[$0].length < first.metainfo.files[$1].length
                       }) {
                        let kind = Torrent.playbackKind(forFileNamed: first.metainfo.files[index].name)
                        store.pendingPlayback = PlaybackRequest(
                            torrent: first.torrent, fileIndex: index, kind: kind)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        if arguments.contains("-OpenFirst") {
            Task {
                for _ in 0..<120 {
                    if let first = store.items.first {
                        path = [first]
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }
}
#endif

struct TVTorrentRow: View {
    let item: TorrentItem

    var body: some View {
        HStack(spacing: 24) {
            Text(item.name)
                .lineLimit(1)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        guard let status = item.status else { return "Starting" }
        if status.isComplete { return byteString(Double(totalBytes)) }
        if case .error = status.state { return "Failed" }
        if item.isPaused { return "Paused · \(percent(status.progress))" }
        if case .metadata = status.state { return "Connecting" }
        guard let seconds = remainingSeconds(status, metainfo: item.metainfo) else {
            return percent(status.progress)
        }
        return "\(percent(status.progress)) · ETA \(durationString(seconds))"
    }

    private var totalBytes: Int64 {
        item.metainfo.files.reduce(Int64(0)) { $0 + Int64($1.length) }
    }
}

func percent(_ progress: Double) -> String {
    "\(Int(progress * 100))%"
}

func stateDescription(_ state: TorrentStatus.State) -> String {
    switch state {
    case .metadata: return "Connecting"
    case .downloading: return "Downloading"
    case .seeding: return "Seeding"
    case .paused: return "Paused"
    case .error(let message): return "Error: \(message)"
    }
}

struct TVAddTorrentView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String) throws -> Void

    @State private var magnet = ""
    @State private var addError: String?

    private var trimmed: String { magnet.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
                Section {
                    TextField("magnet:?xt=urn:btih:…", text: $magnet)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Add Torrent") {
                        add(trimmed)
                    }
                    .disabled(trimmed.isEmpty)
                } footer: {
                    Text("Selecting the field shows a keyboard notification on your iPhone, so you can paste a link there.")
                }
                Section("Free Films") {
                    Button("Big Buck Bunny") {
                        add(sampleMagnet)
                    }
                    ForEach(otherSamples, id: \.name) { sample in
                        Button(sample.name) {
                            add(sample.magnet)
                        }
                    }
                }
            }
            .navigationTitle("Add Magnet Link")
        .alert("Could Not Add Torrent", isPresented: Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )) {
            Button("OK", role: .cancel) { addError = nil }
        } message: {
            Text(addError ?? "")
        }
    }

    private func add(_ text: String) {
        do {
            try onAdd(text)
            dismiss()
        } catch {
            addError = error.localizedDescription
        }
    }
}

struct TVTorrentDetailView: View {
    let item: TorrentItem
    let store: TorrentStore

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: TorrentItem?

    private var fileIndicesBySize: [Int] {
        item.metainfo.files.indices.sorted {
            item.metainfo.files[$0].length > item.metainfo.files[$1].length
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(fileIndicesBySize, id: \.self) { index in
                    let file = item.metainfo.files[index]
                    let kind = Torrent.playbackKind(forFileNamed: file.name)
                    let available = item.isPlaybackAvailable(fileIndex: index)
                    Button {
                        store.pendingPlayback = PlaybackRequest(
                            torrent: item.torrent, fileIndex: index, kind: kind)
                    } label: {
                        HStack {
                            if kind != .none {
                                Image(systemName: "play.fill")
                            }
                            Text(file.name).lineLimit(1)
                            Spacer()
                            Text(byteString(Double(file.length)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(kind == .none || !available)
                    .task {
                        item.preparePlaybackAvailability(fileIndex: index)
                    }
                }
            } header: {
                Text("Files")
                    .padding(.bottom, 16)
            }
            if let status = item.status, !status.isComplete {
                Section("Status") {
                    LabeledContent("State", value: stateDescription(status.state))
                    LabeledContent("Progress", value: percent(status.progress))
                    if !item.isPaused {
                        LabeledContent("Download", value: byteRateString(status.downloadRate))
                        LabeledContent("Peers", value: "\(status.peers) (\(status.seeds) seeds)")
                        LabeledContent(
                            "ETA",
                            value: remainingSeconds(status, metainfo: item.metainfo).map(durationString) ?? "-")
                    }
                }
            }
            Section {
                if item.canPause {
                    Button {
                        store.togglePause(item)
                    } label: {
                        Label(item.isPaused ? "Resume" : "Pause", systemImage: item.isPaused ? "play" : "pause")
                    }
                }
                Button(role: .destructive) {
                    pendingDelete = item
                } label: {
                    Label("Delete Torrent", systemImage: "trash")
                }
            }
        }
        .navigationTitle(item.name)
        .deleteTorrentAlert(item: $pendingDelete) { item in
            store.remove(item)
            dismiss()
        }
    }
}

struct TVPlayerView: View {
    let session: TorrentStreamSession
    let store: TorrentStore
    let torrent: Torrent
    let fileIndex: Int
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                TVPlayerController(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
            }
        }
        .task {
            let prepared = await session.makePlayer()
            guard !Task.isCancelled else {
                prepared.pause()
                return
            }
            if let resume = store.playbackPosition(torrent: torrent, fileIndex: fileIndex), resume > 5 {
                await prepared.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            player = prepared
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                persistPosition(from: prepared, onlyWhilePlaying: true)
            }
        }
        .onDisappear {
            if let player {
                persistPosition(from: player, onlyWhilePlaying: false)
            }
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            session.stop()
        }
    }

    private func persistPosition(from stream: AVPlayer, onlyWhilePlaying: Bool) {
        guard let item = stream.currentItem else { return }
        if onlyWhilePlaying, stream.timeControlStatus != .playing { return }
        let seconds = stream.currentTime().seconds
        guard seconds.isFinite, seconds > 5 else { return }
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0, seconds >= duration - 5 { return }
        store.savePlaybackPosition(seconds, torrent: torrent, fileIndex: fileIndex)
    }
}

struct TVPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let controller = AVPlayerViewController()
        controller.player = player
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
