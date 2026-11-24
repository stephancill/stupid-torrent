import Foundation

public enum MediaKind: String, Codable, Sendable, Hashable, CaseIterable {
    case movie
    case series
}

public enum TorrentSearchError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case httpStatus(Int)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Could not build the search request."
        case .httpStatus(let status):
            "The search service returned HTTP \(status)."
        case .invalidData:
            "The search service returned data this app could not read."
        }
    }
}

public struct MediaSearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: MediaKind
    public let name: String
    public let year: String?
    public let posterURL: URL?

    public init(id: String, kind: MediaKind, name: String, year: String?, posterURL: URL?) {
        self.id = id
        self.kind = kind
        self.name = name
        self.year = year
        self.posterURL = posterURL
    }
}

public struct MediaSearchResults: Hashable, Sendable {
    public let movies: [MediaSearchResult]
    public let series: [MediaSearchResult]

    public init(movies: [MediaSearchResult], series: [MediaSearchResult]) {
        self.movies = movies
        self.series = series
    }

    public static let empty = MediaSearchResults(movies: [], series: [])

    public var isEmpty: Bool { movies.isEmpty && series.isEmpty }

    /// Cinemeta ranks movies and series in separate catalogs, so they are shown as separate
    /// sections. The section whose top result best matches the query comes first; ties keep TV
    /// shows first.
    public func sections(query: String) -> [MediaSearchSection] {
        let candidates = [
            MediaSearchSection(kind: .series, results: series),
            MediaSearchSection(kind: .movie, results: movies),
        ].filter { !$0.results.isEmpty }
        return candidates.enumerated().sorted { lhs, rhs in
            let lhsScore = Self.matchScore(name: lhs.element.results[0].name, query: query)
            let rhsScore = Self.matchScore(name: rhs.element.results[0].name, query: query)
            return lhsScore == rhsScore ? lhs.offset < rhs.offset : lhsScore > rhsScore
        }.map(\.element)
    }

    private static func matchScore(name: String, query: String) -> Int {
        let name = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if name == query { return 2 }
        if name.hasPrefix(query) { return 1 }
        return 0
    }
}

public struct MediaSearchSection: Identifiable, Hashable, Sendable {
    public let kind: MediaKind
    public let results: [MediaSearchResult]

    public var id: MediaKind { kind }

    public var title: String { kind == .series ? "TV Shows" : "Movies" }
}

public enum StreamResolution: Int, CaseIterable, Comparable, Sendable {
    case uhd
    case fullHD
    case hd
    case sd
    case other

    public var title: String {
        switch self {
        case .uhd: "4K"
        case .fullHD: "1080p"
        case .hd: "720p"
        case .sd: "480p"
        case .other: "Other"
        }
    }

    public static func < (lhs: StreamResolution, rhs: StreamResolution) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SeriesEpisode: Identifiable, Hashable, Sendable {
    public let id: String
    public let number: Int
    public let name: String
    public let overview: String?

    public init(id: String, number: Int, name: String, overview: String?) {
        self.id = id
        self.number = number
        self.name = name
        self.overview = overview
    }
}

public struct SeriesSeason: Identifiable, Hashable, Sendable {
    public let number: Int
    public let episodes: [SeriesEpisode]

    public var id: Int { number }

    public var title: String { number == 0 ? "Specials" : "Season \(number)" }
}

public struct SeriesInfo: Hashable, Sendable {
    public let id: String
    public let name: String
    public let year: String?
    public let overview: String?
    public let posterURL: URL?
    public let seasons: [SeriesSeason]
}

public struct TorrentioStream: Identifiable, Hashable, Sendable {
    public let id: String
    public let infoHash: String
    public let fileIdx: Int?
    public let filename: String?
    /// The last non-metadata line of Torrentio's title, e.g. the file name or a release name.
    public let titleLine: String?
    public let quality: String?
    /// The first content line of Torrentio's title: the torrent's own name.
    public let releaseName: String?
    public let seeders: Int?
    public let sizeBytes: Int64?
    public let provider: String?
    public let trackers: [URL]

    public var displayName: String {
        filename ?? titleLine ?? infoHash
    }

    public var subtitle: String {
        [quality, sizeBytes.map { byteString(Double($0)) }, provider]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    public var resolution: StreamResolution {
        let haystack = "\(quality ?? "") \(displayName)".lowercased()
        if haystack.contains("2160p") || haystack.contains("4k") { return .uhd }
        if haystack.contains("1080p") { return .fullHD }
        if haystack.contains("720p") { return .hd }
        if haystack.contains("480p") { return .sd }
        return .other
    }

    /// True when the torrent bundles several episodes (its name has no episode marker but the
    /// listed file does), so adding it downloads the whole pack, not one episode.
    public var isEpisodePack: Bool {
        guard let releaseName, releaseName != displayName else { return false }
        return !Self.hasEpisodeMarker(releaseName) && Self.hasEpisodeMarker(displayName)
    }

    private static func hasEpisodeMarker(_ value: String) -> Bool {
        value.firstMatch(of: /(?i)s\d{1,2}\s?e\d{1,3}|\b\d{1,2}x\d{2,3}\b/) != nil
    }

    /// A magnet link that resolves this exact torrent and includes the scrape's trackers. Torrents
    /// without scraped trackers fall back to a small set of public trackers so resolution does not
    /// depend on DHT alone.
    public func magnetLink() -> String {
        var parts = ["xt=urn:btih:\(infoHash)"]
        parts.append("dn=\(Self.percentEncode(displayName))")
        let usableTrackers = trackers.isEmpty ? TorrentioClient.defaultTrackers : trackers
        var seen = Set<String>()
        for tracker in usableTrackers {
            let value = tracker.absoluteString
            guard seen.insert(value).inserted else { continue }
            parts.append("tr=\(Self.percentEncode(value))")
        }
        return "magnet:?" + parts.joined(separator: "&")
    }

    private static let magnetAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: magnetAllowed) ?? value
    }
}

public struct CinemetaClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://v3-cinemeta.strem.io")!

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = CinemetaClient.defaultBaseURL) {
        self.init(baseURL: baseURL, session: TorrentSearchHTTP.session)
    }

    init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    public func search(_ query: String) async throws -> MediaSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        async let movies = catalog(kind: .movie, query: trimmed)
        async let series = catalog(kind: .series, query: trimmed)
        return MediaSearchResults(movies: try await movies, series: try await series)
    }

    public func series(id: String) async throws -> SeriesInfo {
        guard let url = URL(string: "\(baseURL.absoluteString)/meta/series/\(id).json") else {
            throw TorrentSearchError.invalidURL
        }
        let data = try await TorrentSearchHTTP.get(url, session: session)
        return try Self.parseSeries(from: data)
    }

    private func catalog(kind: MediaKind, query: String) async throws -> [MediaSearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "\(baseURL.absoluteString)/catalog/\(kind.rawValue)/top/search=\(encoded).json")
        else {
            throw TorrentSearchError.invalidURL
        }
        let data = try await TorrentSearchHTTP.get(url, session: session)
        return try Self.parseSearch(from: data, kind: kind)
    }

    public static func parseSearch(from data: Data, kind: MediaKind) throws -> [MediaSearchResult] {
        let response: CinemetaCatalogResponse
        do {
            response = try JSONDecoder().decode(CinemetaCatalogResponse.self, from: data)
        } catch {
            throw TorrentSearchError.invalidData
        }
        var seen = Set<String>()
        return response.metas.compactMap { meta in
            guard !meta.id.isEmpty, !meta.name.isEmpty, seen.insert(meta.id).inserted else { return nil }
            return MediaSearchResult(
                id: meta.id,
                kind: kind,
                name: meta.name,
                year: meta.releaseInfo,
                posterURL: meta.poster.flatMap(URL.init(string:))
            )
        }
    }

    public static func parseSeries(from data: Data) throws -> SeriesInfo {
        let response: CinemetaMetaResponse
        do {
            response = try JSONDecoder().decode(CinemetaMetaResponse.self, from: data)
        } catch {
            throw TorrentSearchError.invalidData
        }
        let meta = response.meta
        var episodesBySeason: [Int: [SeriesEpisode]] = [:]
        for video in meta.videos ?? [] {
            guard let season = video.season, season > 0 else { continue }
            let number = video.episode ?? video.number ?? 0
            guard number > 0 else { continue }
            episodesBySeason[season, default: []].append(SeriesEpisode(
                id: video.id,
                number: number,
                name: video.name ?? "Episode \(number)",
                overview: video.overview ?? video.description
            ))
        }
        let seasons = episodesBySeason.keys.sorted().map { number in
            SeriesSeason(
                number: number,
                episodes: (episodesBySeason[number] ?? []).sorted { $0.number < $1.number }
            )
        }
        return SeriesInfo(
            id: meta.id,
            name: meta.name,
            year: meta.releaseInfo,
            overview: meta.description,
            posterURL: meta.poster.flatMap(URL.init(string:)),
            seasons: seasons
        )
    }
}

public struct TorrentioClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://torrentio.strem.fun")!

    /// Used only for scrapes that came without tracker sources, so the magnet is not DHT-only.
    public static let defaultTrackers: [URL] = [
        URL(string: "udp://tracker.opentrackr.org:1337/announce")!,
        URL(string: "udp://open.stealth.si:80/announce")!,
        URL(string: "udp://tracker.torrent.eu.org:451/announce")!,
        URL(string: "udp://explodie.org:6969/announce")!,
    ]

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = TorrentioClient.defaultBaseURL) {
        self.init(baseURL: baseURL, session: TorrentSearchHTTP.session)
    }

    init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `id` is an IMDb id for movies (`tt…`) and an episode id for series (`tt…:S:E`).
    public func streams(kind: MediaKind, id: String) async throws -> [TorrentioStream] {
        guard let url = URL(string: "\(baseURL.absoluteString)/stream/\(kind.rawValue)/\(id).json") else {
            throw TorrentSearchError.invalidURL
        }
        let data = try await TorrentSearchHTTP.get(url, session: session)
        return try Self.parseStreams(from: data)
    }

    public static func parseStreams(from data: Data) throws -> [TorrentioStream] {
        let response: TorrentioResponse
        do {
            response = try JSONDecoder().decode(TorrentioResponse.self, from: data)
        } catch {
            throw TorrentSearchError.invalidData
        }
        return (response.streams ?? []).enumerated().compactMap { index, raw in
            guard let infoHash = raw.infoHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  infoHash.count == 40,
                  infoHash.allSatisfy(\.isHexDigit)
            else { return nil }
            let title = raw.title ?? ""
            let lines = contentLines(of: title)
            let trackers = (raw.sources ?? []).compactMap { source -> URL? in
                guard source.hasPrefix("tracker:") else { return nil }
                return URL(string: String(source.dropFirst("tracker:".count)))
            }
            let filename = raw.behaviorHints?.filename
            return TorrentioStream(
                id: "\(infoHash)-\(raw.fileIdx ?? -1)-\(index)",
                infoHash: infoHash,
                fileIdx: raw.fileIdx,
                filename: filename,
                titleLine: preferredTitleLine(from: lines),
                quality: quality(from: raw.name, title: title, filename: filename),
                releaseName: lines.first,
                seeders: seeders(from: title),
                sizeBytes: sizeBytes(from: title),
                provider: provider(from: title),
                trackers: trackers
            )
        }
    }

    private static func contentLines(of title: String) -> [String] {
        title
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isMetadataLine($0) && !isFlagLine($0) }
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        line.unicodeScalars.contains { scalar in
            scalar.value == 0x1F464 || scalar.value == 0x1F4BE || scalar.value == 0x2699
        }
    }

    private static let fileExtensions = [
        "mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "mpg", "mpeg", "wmv", "flv", "srt", "iso",
    ]

    /// Prefer a line that names a media file (multi-file torrents put it below the release name), so
    /// a trailing audio/flag line does not become the row title; otherwise use the first content line.
    private static func preferredTitleLine(from lines: [String]) -> String? {
        lines.last(where: { line in
            let lowered = line.lowercased()
            return fileExtensions.contains { lowered.contains(".\($0)") }
        }) ?? lines.first
    }

    private static func isFlagLine(_ line: String) -> Bool {
        let scalars = line.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && scalar != "\u{FE0F}"
        }
        guard !scalars.isEmpty else { return false }
        return scalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }
    }

    private static func seeders(from title: String) -> Int? {
        guard let match = title.firstMatch(of: /👤\s*(\d+)/) else { return nil }
        return Int(match.1)
    }

    /// Torrentio formats sizes with 1024-based units ("263.34 MB" is 276,134,947 bytes).
    private static func sizeBytes(from title: String) -> Int64? {
        guard let match = title.firstMatch(of: /💾\s*([0-9.]+)\s*([kKMGT]?B)/),
              let value = Double(match.1) else { return nil }
        let exponent: Double = switch match.2.uppercased() {
        case "KB": 1
        case "MB": 2
        case "GB": 3
        case "TB": 4
        default: 0
        }
        return Int64((value * pow(1024, exponent)).rounded())
    }

    private static func provider(from title: String) -> String? {
        for line in title.split(separator: "\n").reversed() {
            let scalars = line.unicodeScalars
            guard let gear = scalars.firstIndex(where: { $0.value == 0x2699 }) else { continue }
            var remainder = String(String.UnicodeScalarView(scalars[scalars.index(after: gear)...]))
            if remainder.hasPrefix("\u{FE0F}") { remainder.removeFirst() }
            let provider = remainder.trimmingCharacters(in: .whitespaces)
            if !provider.isEmpty { return provider }
        }
        return nil
    }

    private static func quality(from name: String?, title: String, filename: String?) -> String? {
        if let name {
            let parts = name
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.lowercased() != "torrentio" }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        let haystack = "\(filename ?? "") \(title)"
        for (token, label) in [
            ("2160p", "4K"), ("1080p", "1080p"), ("720p", "720p"), ("480p", "480p"),
        ] where haystack.localizedCaseInsensitiveContains(token) {
            return label
        }
        return nil
    }
}

enum TorrentSearchHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "stupid-torrent-client"]
        return URLSession(configuration: configuration)
    }()

    static func get(_ url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw TorrentSearchError.invalidData }
        guard (200..<300).contains(http.statusCode) else {
            throw TorrentSearchError.httpStatus(http.statusCode)
        }
        return data
    }
}

private struct CinemetaCatalogResponse: Decodable {
    let metas: [CinemetaMeta]
}

private struct CinemetaMetaResponse: Decodable {
    let meta: CinemetaMeta
}

private struct CinemetaMeta: Decodable {
    let id: String
    let name: String
    let releaseInfo: String?
    let poster: String?
    let description: String?
    let videos: [CinemetaVideo]?
}

private struct CinemetaVideo: Decodable {
    let id: String
    let name: String?
    let season: Int?
    let episode: Int?
    let number: Int?
    let overview: String?
    let description: String?
}

private struct TorrentioResponse: Decodable {
    let streams: [TorrentioRawStream]?
}

private struct TorrentioRawStream: Decodable {
    let name: String?
    let title: String?
    let infoHash: String?
    let fileIdx: Int?
    let behaviorHints: TorrentioBehaviorHints?
    let sources: [String]?
}

private struct TorrentioBehaviorHints: Decodable {
    let filename: String?
}
