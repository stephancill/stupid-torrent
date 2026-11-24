import SwiftUI
import StupidClientCore

struct TorrentStreamsRequest: Hashable {
    let title: String
    let subtitle: String?
    let kind: MediaKind
    let mediaID: String
}

struct TorrentSearchView: View {
    let store: TorrentStore

    @State private var query = ""
    @State private var results = MediaSearchResults.empty
    @State private var isSearching = false
    @State private var searchError: String?

    private let cinemeta = CinemetaClient()

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .navigationDestination(for: MediaSearchResult.self) { result in
                    if result.kind == .series {
                        SeriesEpisodesView(result: result, store: store)
                    } else {
                        TorrentStreamsView(
                            request: TorrentStreamsRequest(
                                title: result.name,
                                subtitle: result.year,
                                kind: .movie,
                                mediaID: result.id
                            ),
                            store: store
                        )
                    }
                }
                .navigationDestination(for: TorrentStreamsRequest.self) { request in
                    TorrentStreamsView(request: request, store: store)
                }
                .navigationDestination(for: TorrentItem.self) { item in
                    TorrentDetailView(item: item, store: store)
                }
                .searchable(text: $query, prompt: "Movies and TV shows")
                .toolbar {
                    if isSearching && !results.isEmpty {
                        ToolbarItem {
                            ProgressView()
                        }
                    }
                }
                .task(id: trimmedQuery) {
                    await search()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            ContentUnavailableView(
                "Find Movies & TV",
                systemImage: "magnifyingglass",
                description: Text("Search for a title, then pick a torrent to download.")
            )
        } else if let searchError {
            ContentUnavailableView {
                Label("Search Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(searchError)
            } actions: {
                Button("Try Again") {
                    Task { await search(debounce: false) }
                }
            }
        } else if isSearching && results.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            List {
                ForEach(results.sections(query: trimmedQuery)) { section in
                    Section(section.title) {
                        ForEach(section.results) { result in
                            NavigationLink(value: result) {
                                MediaResultRow(result: result)
                            }
                        }
                    }
                }
            }
        }
    }

    private func search(debounce: Bool = true) async {
        let query = trimmedQuery
        guard !query.isEmpty else {
            results = .empty
            searchError = nil
            isSearching = false
            return
        }
        if debounce {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        isSearching = true
        searchError = nil
        do {
            let found = try await cinemeta.search(query)
            guard !Task.isCancelled else { return }
            results = found
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = .empty
            searchError = error.localizedDescription
        }
        isSearching = false
    }
}

private struct PosterImage: View {
    let url: URL?
    let width: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct MediaResultRow: View {
    let result: MediaSearchResult

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: result.posterURL, width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                if let year = result.year, !year.isEmpty {
                    Text(year)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SeriesEpisodesView: View {
    let result: MediaSearchResult
    let store: TorrentStore

    @State private var info: SeriesInfo?
    @State private var seasonNumber = 1
    @State private var isLoading = true
    @State private var error: String?

    private let cinemeta = CinemetaClient()

    var body: some View {
        Group {
            if let info {
                episodesList(info)
            } else if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Could Not Load Episodes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error ?? "No episodes are available for this show.")
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
            }
        }
        .navigationTitle(result.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let info, info.seasons.count > 1 {
                ToolbarItem {
                    Picker("Season", selection: $seasonNumber) {
                        ForEach(info.seasons) { season in
                            Text(season.title).tag(season.number)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .task {
            await load()
        }
    }

    private func episodesList(_ info: SeriesInfo) -> some View {
        List {
            Section {
                SeriesHeader(info: info)
            }
            if let season = info.seasons.first(where: { $0.number == seasonNumber }) {
                Section(season.title) {
                    ForEach(season.episodes) { episode in
                        NavigationLink(value: TorrentStreamsRequest(
                            title: episode.name,
                            subtitle: "\(info.name) · S\(season.number)E\(episode.number)",
                            kind: .series,
                            mediaID: episode.id
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(episode.number). \(episode.name)")
                                    .lineLimit(1)
                                if let overview = episode.overview, !overview.isEmpty {
                                    Text(overview)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard info == nil else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let fetched = try await cinemeta.series(id: result.id)
            guard !Task.isCancelled else { return }
            if fetched.seasons.isEmpty {
                error = "No episodes are available for this show."
            } else {
                info = fetched
                seasonNumber = fetched.seasons.first?.number ?? 1
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct SeriesHeader: View {
    let info: SeriesInfo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: info.posterURL, width: 72)
            VStack(alignment: .leading, spacing: 4) {
                if let year = info.year, !year.isEmpty {
                    Text(year)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let overview = info.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.subheadline)
                        .lineLimit(6)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TorrentStreamsView: View {
    let request: TorrentStreamsRequest
    let store: TorrentStore

    @State private var streams: [TorrentioStream] = []
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var addError: String?
    @State private var addedCount = 0

    private let torrentio = TorrentioClient()

    private var groups: [(resolution: StreamResolution, streams: [TorrentioStream])] {
        Dictionary(grouping: streams, by: \.resolution)
            .sorted { $0.key < $1.key }
            .map { (resolution: $0.key, streams: $0.value) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("Could Not Load Torrents", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
            } else if streams.isEmpty {
                ContentUnavailableView(
                    "No Torrents Found",
                    systemImage: "tray",
                    description: Text("There are no torrents for this title yet.")
                )
            } else {
                List {
                    let groups = groups
                    if groups.count > 1 {
                        ForEach(groups, id: \.resolution) { group in
                            Section(group.resolution.title) {
                                ForEach(group.streams) { stream in
                                    row(stream)
                                }
                            }
                        }
                    } else {
                        ForEach(streams) { stream in
                            row(stream)
                        }
                    }
                }
            }
        }
        .navigationTitle(request.title)
        .navigationSubtitle(request.subtitle ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard !hasLoaded else { return }
            await load()
        }
        .sensoryFeedback(.success, trigger: addedCount)
        .alert("Could Not Add Torrent", isPresented: Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )) {
            Button("OK", role: .cancel) { addError = nil }
        } message: {
            Text(addError ?? "")
        }
    }

    @ViewBuilder
    private func row(_ stream: TorrentioStream) -> some View {
        Group {
            if let item = store.items.first(where: { $0.id == stream.infoHash }) {
                NavigationLink(value: item) {
                    TorrentioStreamRow(stream: stream, request: request, state: .added)
                }
            } else if store.resolvingItems.contains(where: { $0.id == stream.infoHash }) {
                TorrentioStreamRow(stream: stream, request: request, state: .adding)
            } else {
                Button {
                    add(stream)
                } label: {
                    TorrentioStreamRow(stream: stream, request: request, state: .available)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button {
                copyToClipboard(stream.magnetLink())
            } label: {
                Label("Copy Magnet", systemImage: "link")
            }
        }
    }

    private func add(_ stream: TorrentioStream) {
        do {
            try store.addMagnet(stream.magnetLink())
            addedCount += 1
        } catch {
            addError = error.localizedDescription
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let found = try await torrentio.streams(kind: request.kind, id: request.mediaID)
            guard !Task.isCancelled else { return }
            streams = found
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct TorrentioStreamRow: View {
    enum RowState {
        case available
        case adding
        case added
    }

    let stream: TorrentioStream
    let request: TorrentStreamsRequest
    let state: RowState

    private var details: String {
        var parts: [String] = []
        if request.kind == .series && stream.isEpisodePack {
            parts.append("Season pack")
        }
        if let seeders = stream.seeders {
            parts.append(seeders == 1 ? "1 seeder" : "\(seeders) seeders")
        }
        if let quality = stream.quality, quality != stream.resolution.title {
            parts.append(quality)
        }
        if let sizeBytes = stream.sizeBytes {
            parts.append(byteString(Double(sizeBytes)))
        }
        if let provider = stream.provider {
            parts.append(provider)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(stream.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            Spacer(minLength: 8)
            switch state {
            case .available:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.tint)
                    .imageScale(.large)
            case .adding:
                ProgressView()
            case .added:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
        .accessibilityHint(state == .available ? "Downloads this torrent" : "")
    }

    private var accessibilityState: String {
        switch state {
        case .available: ""
        case .adding: "Adding"
        case .added: "Added"
        }
    }
}

private func copyToClipboard(_ string: String) {
    #if os(iOS)
    UIPasteboard.general.string = string
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #endif
}
