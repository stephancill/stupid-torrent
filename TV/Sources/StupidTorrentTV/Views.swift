import AVFoundation
import AVKit
import Streaming
import StupidClientCore
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
    @Environment(\.scenePhase) private var scenePhase

    private var isBusy: Bool {
        !store.resolvingItems.isEmpty || store.items.contains { $0.status?.state == .downloading }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Torrent", systemImage: "plus")
                    }
                }
                if !store.resolvingItems.isEmpty {
                    Section("Finding Metadata") {
                        ForEach(store.resolvingItems) { item in
                            HStack {
                                ProgressView()
                                Text(item.name).lineLimit(1)
                            }
                        }
                    }
                }
                if !store.items.isEmpty {
                    Section("Torrents") {
                        ForEach(store.items) { item in
                            NavigationLink(value: item) {
                                TVTorrentRow(item: item)
                            }
                        }
                    }
                }
            }
            .navigationTitle("stupid torrent")
            .navigationDestination(for: TorrentItem.self) { item in
                TVTorrentDetailView(item: item, store: store)
            }
            .fullScreenCover(isPresented: $showAdd) {
                TVAddTorrentView { magnet in
                    try store.addMagnet(magnet)
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

#if DEBUG
extension TVContentView {
    /// Opens screens from launch arguments so the simulator can be screenshotted without remote
    /// input: `-ShowAdd`, `-AddSample` (adds Big Buck Bunny), `-OpenFirst` (opens the first
    /// torrent once it exists), `-PlayFirst` (plays its largest file).
    fileprivate func applyDebugLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
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
        if status.isComplete { return "Done" }
        if case .error(let message) = status.state { return "Error: \(message)" }
        if item.isPaused { return "Paused \(percent(status.progress))" }
        if case .metadata = status.state { return "Finding metadata, \(status.peers) peers" }
        var parts = [
            percent(status.progress), byteRateString(status.downloadRate), "\(status.peers) peers",
        ]
        if let seconds = remainingSeconds(status, metainfo: item.metainfo) {
            parts.append("ETA \(durationString(seconds))")
        }
        return parts.joined(separator: "  ")
    }
}

func percent(_ progress: Double) -> String {
    String(format: "%.1f%%", progress * 100)
}

func stateDescription(_ state: TorrentStatus.State) -> String {
    switch state {
    case .metadata: return "Finding metadata"
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
        VStack(alignment: .leading, spacing: 40) {
            Text("Add Torrent")
                .font(.title2)
                .bold()
            Text("Enter a magnet link. Your iPhone shows a keyboard notification when this field is selected, so you can paste a link from it.")
                .foregroundStyle(.secondary)
            TextField("magnet:?xt=urn:btih:…", text: $magnet)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !trimmed.isEmpty {
                Text(trimmed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack(spacing: 40) {
                Button("Add") {
                    add(trimmed)
                }
                .disabled(trimmed.isEmpty)
            }
            Text("Samples")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(spacing: 40) {
                Button("Big Buck Bunny") {
                    add(sampleMagnet)
                }
                ForEach(otherSamples, id: \.name) { sample in
                    Button(sample.name) {
                        add(sample.magnet)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 160)
        .padding(.vertical, 100)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
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
    @State private var confirmDelete = false

    private var fileIndicesBySize: [Int] {
        item.metainfo.files.indices.sorted {
            item.metainfo.files[$0].length > item.metainfo.files[$1].length
        }
    }

    var body: some View {
        List {
            if let status = item.status, !status.isComplete {
                Section("Status") {
                    LabeledContent("State", value: stateDescription(status.state))
                    LabeledContent(
                        "Progress",
                        value: "\(percent(status.progress)) (\(status.verifiedCount)/\(status.pieceCount) pieces)")
                    LabeledContent("Download", value: byteRateString(status.downloadRate))
                    LabeledContent("Peers", value: "\(status.peers) (\(status.seeds) seeds)")
                    LabeledContent(
                        "ETA",
                        value: remainingSeconds(status, metainfo: item.metainfo).map(durationString) ?? "-")
                }
            }
            Section("Files") {
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
            }
            Section {
                if item.canPause {
                    Button(item.isPaused ? "Resume" : "Pause") {
                        store.togglePause(item)
                    }
                }
                Button("Delete", role: .destructive) {
                    confirmDelete = true
                }
            }
        }
        .navigationTitle(item.name)
        .confirmationDialog(
            "Delete \"\(item.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.remove(item)
                dismiss()
            }
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
