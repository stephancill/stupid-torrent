import StupidClientCore
import SwiftUI

struct TorrentStreamsRequest: Hashable {
    let title: String
    let subtitle: String?
    let kind: MediaKind
    let mediaID: String
}

#if DEBUG
private enum SearchDebug {
    static var query: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-SearchQuery"), index + 1 < arguments.count else { return "" }
        return arguments[index + 1]
    }

    static var opensFirst: Bool { opensEpisode || ProcessInfo.processInfo.arguments.contains("-SearchOpenFirst") }

    static var opensEpisode: Bool { ProcessInfo.processInfo.arguments.contains("-SearchOpenEpisode") }

    static var activatesField: Bool { ProcessInfo.processInfo.arguments.contains("-SearchActivate") }
}
#endif

private struct SearchQueryField: ViewModifier {
    @Binding var query: String
    @Binding var isActive: Bool
    @FocusState private var isFocused: Bool

    private let prompt = "Movies and TV shows"

    func body(content: Content) -> some View {
        #if os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            content
                .safeAreaInset(edge: .top) {
                    TextField(prompt, text: $query)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($isFocused)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                .onChange(of: isActive) { _, active in isFocused = active }
                .onChange(of: isFocused) { _, focused in isActive = focused }
        } else {
            content.searchable(text: $query, isPresented: $isActive, prompt: prompt)
        }
        #elseif os(tvOS)
        content.searchable(text: $query, prompt: prompt)
        #else
        content.searchable(text: $query, isPresented: $isActive, prompt: prompt)
        #endif
    }
}

#if os(tvOS)
private let resultPosterWidth: CGFloat = 240
private let headerPosterWidth: CGFloat = 120
#else
private let resultPosterWidth: CGFloat = 44
private let headerPosterWidth: CGFloat = 72
#endif

public struct TorrentSearchView<Detail: View>: View {
    let store: TorrentStore
    let detail: (TorrentItem) -> Detail

    @State private var query = ""
    @State private var isSearchPresented = false
    @State private var path = NavigationPath()
    @State private var search = Loadable<MediaSearchResults>()

    private let cinemeta = CinemetaClient()

    public init(store: TorrentStore, @ViewBuilder detail: @escaping (TorrentItem) -> Detail) {
        self.store = store
        self.detail = detail
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        NavigationStack(path: $path) {
            content
                #if !os(tvOS)
                .navigationTitle("Search")
                #endif
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
                    detail(item)
                }
                .modifier(SearchQueryField(query: $query, isActive: $isSearchPresented))
                #if !os(tvOS)
                .toolbar {
                    if search.isLoading, search.value?.isEmpty == false {
                        ToolbarItem {
                            ProgressView()
                        }
                    }
                }
                #endif
                .task(id: trimmedQuery) {
                    await runSearch()
                }
                #if DEBUG
                .onAppear {
                    if query.isEmpty { query = SearchDebug.query }
                }
                .task {
                    guard SearchDebug.activatesField else { return }
                    try? await Task.sleep(for: .seconds(1))
                    isSearchPresented = true
                    try? await Task.sleep(for: .seconds(2))
                    if !isSearchPresented { fatalError("SearchDebug: not presented") }
                }
                .onChange(of: search.value) { _, results in
                    if SearchDebug.opensFirst, path.isEmpty,
                       let first = results?.sections(query: trimmedQuery).first?.results.first {
                        path.append(first)
                    }
                }
                #endif
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
        } else {
            LoadableContent(state: search, failureTitle: "Search Failed", retry: { await runSearch(debounce: false) }) { results in
                if results.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                } else {
                    resultsView(results)
                }
            }
        }
    }

    #if os(tvOS)
    private func resultsView(_ results: MediaSearchResults) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 48) {
                ForEach(results.sections(query: trimmedQuery)) { section in
                    VStack(alignment: .leading, spacing: 24) {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 48) {
                                ForEach(section.results) { result in
                                    NavigationLink(value: result) {
                                        MediaLockup(result: result)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 32)
                        }
                        .scrollClipDisabled()
                    }
                }
            }
            .padding(.horizontal, 80)
        }
    }
    #else
    private func resultsView(_ results: MediaSearchResults) -> some View {
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
    #endif

    private func runSearch(debounce: Bool = true) async {
        let query = trimmedQuery
        guard !query.isEmpty else {
            search = Loadable()
            return
        }
        if debounce {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        await load($search) { try await cinemeta.search(query) }
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
        .clipShape(RoundedRectangle(cornerRadius: width > 100 ? 12 : 6))
    }
}

#if os(tvOS)
private struct MediaLockup: View {
    let result: MediaSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PosterImage(url: result.posterURL, width: resultPosterWidth)
                .hoverEffect(.highlight)
            Text(result.name)
                .lineLimit(1)
            if let year = result.year, !year.isEmpty {
                Text(year)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: resultPosterWidth, alignment: .leading)
    }
}
#else
private struct MediaResultRow: View {
    let result: MediaSearchResult

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: result.posterURL, width: resultPosterWidth)
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
#endif

private struct SeriesEpisodesView: View {
    let result: MediaSearchResult
    let store: TorrentStore

    @State private var series = Loadable<SeriesInfo>()
    @State private var seasonNumber = 1
    @State private var debugEpisode: TorrentStreamsRequest?

    private let cinemeta = CinemetaClient()

    var body: some View {
        LoadableContent(state: series, failureTitle: "Could Not Load Episodes", retry: loadSeries) { info in
            episodesList(info)
        }
        .navigationTitle(result.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if !os(tvOS)
        .toolbar {
            if let info = series.value, info.seasons.count > 1 {
                ToolbarItem {
                    seasonPicker(info)
                        .pickerStyle(.menu)
                }
            }
        }
        #endif
        .task {
            await loadSeries()
        }
        #if DEBUG
        .navigationDestination(item: $debugEpisode) { request in
            TorrentStreamsView(request: request, store: store)
        }
        #endif
    }

    private func seasonPicker(_ info: SeriesInfo) -> some View {
        Picker("Season", selection: $seasonNumber) {
            ForEach(info.seasons) { season in
                Text(season.title).tag(season.number)
            }
        }
    }

    private func episodesList(_ info: SeriesInfo) -> some View {
        List {
            Section {
                SeriesHeader(info: info)
                #if os(tvOS)
                if info.seasons.count > 1 {
                    seasonPicker(info)
                }
                #endif
            }
            if let season = info.seasons.first(where: { $0.number == seasonNumber }) {
                Section(season.title) {
                    ForEach(season.episodes) { episode in
                        NavigationLink(value: streamsRequest(show: info, season: season, episode: episode)) {
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

    private func streamsRequest(show: SeriesInfo, season: SeriesSeason, episode: SeriesEpisode) -> TorrentStreamsRequest {
        TorrentStreamsRequest(
            title: episode.name,
            subtitle: "\(show.name) · S\(season.number)E\(episode.number)",
            kind: .series,
            mediaID: episode.id
        )
    }

    private func loadSeries() async {
        guard series.value == nil else { return }
        await load($series) {
            let info = try await cinemeta.series(id: result.id)
            guard !info.seasons.isEmpty else { throw NoEpisodesError() }
            return info
        }
        guard let info = series.value else { return }
        seasonNumber = info.seasons.first?.number ?? 1
        #if DEBUG
        if SearchDebug.opensEpisode, let season = info.seasons.first, let episode = season.episodes.first {
            debugEpisode = streamsRequest(show: info, season: season, episode: episode)
        }
        #endif
    }
}

private struct NoEpisodesError: LocalizedError {
    var errorDescription: String? { "No episodes are available for this show." }
}

private struct SeriesHeader: View {
    let info: SeriesInfo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: info.posterURL, width: headerPosterWidth)
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

    @State private var streams = Loadable<[TorrentioStream]>()
    @State private var addError: String?
    @State private var addedCount = 0

    private let torrentio = TorrentioClient()

    private func groups(_ streams: [TorrentioStream]) -> [(resolution: StreamResolution, streams: [TorrentioStream])] {
        Dictionary(grouping: streams, by: \.resolution)
            .sorted { $0.key < $1.key }
            .map { (resolution: $0.key, streams: $0.value) }
    }

    var body: some View {
        LoadableContent(state: streams, failureTitle: "Could Not Load Torrents", retry: loadStreams) { streams in
            if streams.isEmpty {
                ContentUnavailableView(
                    "No Torrents Found",
                    systemImage: "tray",
                    description: Text("There are no torrents for this title yet.")
                )
            } else {
                List {
                    #if os(tvOS)
                    if let subtitle = request.subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    #endif
                    let groups = groups(streams)
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
        #if os(iOS)
        .navigationSubtitle(request.subtitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: addedCount)
        #endif
        .task {
            await loadStreams()
        }
        .errorAlert("Could Not Add Torrent", message: $addError)
    }

    @ViewBuilder
    private func row(_ stream: TorrentioStream) -> some View {
        Group {
            if let item = store.item(infoHash: stream.infoHash) {
                NavigationLink(value: item) {
                    TorrentioStreamRow(stream: stream, request: request, state: .added)
                }
            } else if store.isResolving(infoHash: stream.infoHash) {
                TorrentioStreamRow(stream: stream, request: request, state: .adding)
            } else {
                Button {
                    add(stream)
                } label: {
                    TorrentioStreamRow(stream: stream, request: request, state: .available)
                }
                #if !os(tvOS)
                .buttonStyle(.plain)
                #endif
            }
        }
        #if !os(tvOS)
        .contextMenu {
            Button {
                copyToClipboard(stream.magnetLink())
            } label: {
                Label("Copy Magnet", systemImage: "link")
            }
        }
        #endif
    }

    private func add(_ stream: TorrentioStream) {
        do {
            try store.addMagnet(stream.magnetLink())
            addedCount += 1
        } catch {
            addError = error.localizedDescription
        }
    }

    private func loadStreams() async {
        guard streams.value == nil else { return }
        await load($streams) { try await torrentio.streams(kind: request.kind, id: request.mediaID) }
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
            parts.append(stream.isMultiSeasonPack ? "Multi-season pack" : "Season pack")
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
            #if !os(tvOS)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            #endif
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
