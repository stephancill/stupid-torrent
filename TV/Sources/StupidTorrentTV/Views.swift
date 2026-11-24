import StupidClientCore
import StupidClientUI
import SwiftUI
import TorrentCore

private let sampleMagnet =
    "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce"

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
            TorrentPlayerView(request: request, store: store)
        }
        .errorAlert("Could Not Add Torrent", message: $store.addError)
        .keepsScreenAwake(while: store.needsNetwork)
        .onAppear {
            store.restore()
            #if DEBUG
            applyDebugLaunchArguments()
            #endif
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
                if let first = await store.firstItem(), let index = first.fileIndicesBySize.first {
                    store.play(item: first, fileIndex: index)
                }
            }
        }
        if arguments.contains("-OpenFirst") {
            Task {
                if let first = await store.firstItem() {
                    path = [first]
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
        let status = item.status
        if item.isComplete { return byteString(Double(item.metainfo.totalLength)) }
        if item.isPaused { return "Paused · \(percentString(status.progress))" }
        guard let seconds = remainingSeconds(status, metainfo: item.metainfo) else {
            return percentString(status.progress)
        }
        return "\(percentString(status.progress)) · ETA \(durationString(seconds))"
    }
}

private func stateDescription(_ state: TorrentStatus.State) -> String {
    switch state {
    case .downloading: "Downloading"
    case .seeding: "Seeding"
    case .paused: "Paused"
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
        .errorAlert("Could Not Add Torrent", message: $addError)
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

    var body: some View {
        List {
            Section {
                ForEach(item.fileIndicesBySize, id: \.self) { index in
                    let file = item.metainfo.files[index]
                    Button {
                        store.play(item: item, fileIndex: index)
                    } label: {
                        HStack {
                            if Torrent.isPlayable(fileNamed: file.name) {
                                Image(systemName: "play.fill")
                            }
                            Text(file.name).lineLimit(1)
                            Spacer()
                            Text(byteString(Double(file.length)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!item.isPlaybackAvailable(fileIndex: index))
                    .task {
                        item.preparePlaybackAvailability(fileIndex: index)
                    }
                }
            } header: {
                Text("Files")
                    .padding(.bottom, 16)
            }
            if !item.isComplete {
                let status = item.status
                Section("Status") {
                    LabeledContent("State", value: stateDescription(status.state))
                    LabeledContent("Progress", value: percentString(status.progress))
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
                if !item.isComplete {
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
