import SwiftUI
import TorrentCore
import StupidClientCore
import StupidClientUI

private enum RootTab: Hashable {
    case torrents
    case search

    static var initial: RootTab {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SearchTab") { return .search }
        #endif
        return .torrents
    }
}

struct ContentView: View {
    @State private var store = TorrentStore()
    @State private var selectedTab = RootTab.initial
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        tabs
        #if os(iOS)
        .fullScreenCover(item: $store.pendingPlayback, onDismiss: {
            OrientationLock.playerPresented = false
        }) { request in
            TorrentPlayerView(request: request, store: store)
                .onAppear { OrientationLock.playerPresented = true }
                .onDisappear { OrientationLock.playerPresented = false }
        }
        #else
        .sheet(item: $store.pendingPlayback) { request in
            TorrentPlayerView(request: request, store: store)
        }
        #endif
        .errorAlert("Could Not Add Torrent", message: $store.addError)
        .keepsScreenAwake(while: store.needsNetwork)
        .onAppear {
            store.restore()
            #if DEBUG
            autoPlayForTesting()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.submitRestoredBackgroundTasks()
            }
        }
        .onChange(of: store.restorationComplete) { _, complete in
            if complete && scenePhase == .active {
                store.submitRestoredBackgroundTasks()
            }
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

    @ViewBuilder
    private var tabs: some View {
        if #available(macOS 15, *) {
            TabView(selection: $selectedTab) {
                Tab("Torrents", systemImage: "arrow.down.circle", value: RootTab.torrents) {
                    TorrentLibraryView(store: store)
                }
                Tab("Search", systemImage: "magnifyingglass", value: RootTab.search, role: .search) {
                    TorrentSearchView(store: store) { item in
                        TorrentDetailView(item: item, store: store)
                    }
                }
            }
        } else {
            TabView {
                TorrentLibraryView(store: store)
                    .tabItem {
                        Label("Torrents", systemImage: "arrow.down.circle")
                    }
                TorrentSearchView(store: store) { item in
                    TorrentDetailView(item: item, store: store)
                }
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }
            }
        }
    }

    #if DEBUG
    private func autoPlayForTesting() {
        let args = ProcessInfo.processInfo.arguments
        var injectedPeer: PeerAddress?
        if let idx = args.firstIndex(of: "-InjectPeer"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            if parts.count == 2, let port = UInt16(parts[1]) {
                injectedPeer = PeerAddress(host: String(parts[0]), port: port)
            }
        }
        let fileIndex = args.firstIndex(of: "-AutoPlayIndex").flatMap { idx in
            idx + 1 < args.count ? Int(args[idx + 1]) : nil
        }
        guard injectedPeer != nil || fileIndex != nil else { return }
        Task {
            guard let item = await store.firstItem() else { return }
            if let injectedPeer {
                TorrentLog.log("AUTOPLAY injecting peer \(injectedPeer.host):\(injectedPeer.port)")
                await item.torrent.addPeer(host: injectedPeer.host, port: injectedPeer.port)
            }
            if let fileIndex, item.metainfo.files.indices.contains(fileIndex),
               Torrent.isPlayable(fileNamed: item.metainfo.files[fileIndex].name) {
                TorrentLog.log("AUTOPLAY opening file \(fileIndex) (\(item.metainfo.files[fileIndex].name))")
                store.play(item: item, fileIndex: fileIndex)
            }
        }
    }
    #endif
}

struct TorrentLibraryView: View {
    let store: TorrentStore

    @State private var showAdd = false
    @State private var showCompleted = true
    @State private var pendingDelete: TorrentItem?

    private var downloadingItems: [TorrentItem] { store.items.filter { !$0.isComplete } }
    private var completedItems: [TorrentItem] { store.items.filter { $0.isComplete } }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty && store.resolvingItems.isEmpty {
                    ContentUnavailableView(
                        "No Torrents",
                        systemImage: "arrow.down.circle",
                        description: Text("Add a magnet link, import a .torrent file, or search for a movie or show in the Search tab.")
                    )
                } else {
                    List {
                        if !store.resolvingItems.isEmpty || !downloadingItems.isEmpty {
                            Section("In Progress") {
                                ForEach(store.resolvingItems) { item in
                                    ResolvingTorrentRow(item: item)
                                }
                                ForEach(downloadingItems) { item in
                                    row(item)
                                }
                            }
                        }
                        if !completedItems.isEmpty {
                            Section("Completed", isExpanded: $showCompleted) {
                                ForEach(completedItems) { item in
                                    row(item)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationDestination(for: TorrentItem.self) { item in
                TorrentDetailView(item: item, store: store)
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
                    switch source {
                    case .magnet(let string):
                        try store.addMagnet(string)
                    case .file(let url):
                        try store.addFile(url)
                    }
                }
            }
            .deleteTorrentAlert(item: $pendingDelete) { item in
                store.remove(item)
            }
        }
    }

    private func row(_ item: TorrentItem) -> some View {
        NavigationLink(value: item) {
            TorrentRow(item: item)
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                pendingDelete = item
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
            if item.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else if item.isPaused {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
            } else {
                PieProgressView(progress: item.status.progress)
                    .frame(width: 20, height: 20)
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
        remainingSeconds(item.status, metainfo: item.metainfo).map { "ETA \(durationString($0))" }
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
                    HStack {
                        TextField("magnet:?xt=urn:btih:…", text: $magnet)
                            .lineLimit(1)
                            .autocorrectionDisabled()
                        PasteButton(payloadType: String.self) { strings in
                            if let pasted = strings.first {
                                magnet = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                    }
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
            .navigationTitle("Add Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result {
                    add(.file(url))
                }
            }
            .errorAlert("Could Not Add Torrent", message: $addError)
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

    var body: some View {
        List {
            if !item.isComplete {
                let status = item.status
                Section("Status") {
                    LabeledContent("Progress", value: item.isPaused ? "\(percentString(status.progress)) (Paused)" : percentString(status.progress))
                    LabeledContent("Pieces", value: "\(status.verifiedCount)/\(status.pieceCount)")
                    if !item.isPaused {
                        LabeledContent("Download", value: byteRateString(status.downloadRate))
                        LabeledContent("ETA", value: remainingSeconds(status, metainfo: item.metainfo).map(durationString) ?? "-")
                        LabeledContent("Peers", value: "\(status.peers) (\(status.seeds) seeds)")
                    }
                }
            }
            Section("Files") {
                ForEach(item.fileIndicesBySize, id: \.self) { index in
                    let file = item.metainfo.files[index]
                    let isPlaybackAvailable = item.isPlaybackAvailable(fileIndex: index)
                    Button {
                        store.play(item: item, fileIndex: index)
                    } label: {
                        HStack {
                            if Torrent.isPlayable(fileNamed: file.name) {
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
    }
}

private struct TorrentDetailMenu: View {
    let item: TorrentItem
    let store: TorrentStore

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: TorrentItem?

    var body: some View {
        Menu {
            if !item.isComplete {
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
                pendingDelete = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .deleteTorrentAlert(item: $pendingDelete) { item in
            store.remove(item)
            dismiss()
        }
    }

    private func copyMagnet() {
        copyToClipboard(MagnetLink.build(
            infoHash: item.id,
            displayName: item.name,
            trackers: item.metainfo.flattenedTrackers
        ))
    }
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
            context.fill(pie, with: .style(.tint))
        }
    }
}
