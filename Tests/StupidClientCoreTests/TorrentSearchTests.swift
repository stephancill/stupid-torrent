import Foundation
import Testing
import TorrentCore
@testable import StupidClientCore

struct TorrentSearchTests {
    private static let torrentioJSON = #"""
    {"streams":[
    {"name":"Torrentio\n4k DV | HDR10+","title":"Severance.S01.2160p.WEB-DL\nSeverance.S01E01.mkv\n👤 78 💾 11.21 GB ⚙️ Rutracker\n🇬🇧 / 🇷🇺","infoHash":"2A6B66671753C2454DD34115B72B0899514F0CA6","fileIdx":1,"behaviorHints":{"bingeGroup":"torrentio|abc","filename":"Severance.S01E01.mkv"},"sources":["dht:2a6b66671753c2454dd34115b72b0899514f0ca6","tracker:udp://tracker.opentrackr.org:1337/announce","tracker:http://bt.example.org/ann?passkey=abc"]},
    {"name":"Torrentio\n1080p","title":"Big Buck Bunny 1080p 30fps\n👤 20 💾 263.34 MB ⚙️ MagnetDL","infoHash":"88594aaacbde40ef3e2510c47374ec0aa396c08e","fileIdx":0,"behaviorHints":{"filename":"bbb_sunflower_1080p_30fps_normal.mp4"}},
    {"name":"Torrentio\n720p","title":"Broken\n👤 1","infoHash":"not-a-hash","fileIdx":0}
    ]}
    """#

    private static let searchJSON = #"""
    {"metas":[
    {"id":"tt1254207","type":"movie","name":"Big Buck Bunny","releaseInfo":"2008","poster":"https://images.metahub.space/poster/small/tt1254207/img"},
    {"id":"tt1254207","type":"movie","name":"Big Buck Bunny Duplicate","releaseInfo":"2008","poster":null}
    ]}
    """#

    private static let seriesJSON = #"""
    {"meta":{
    "id":"tt11280740","name":"Severance","releaseInfo":"2022–","poster":"https://images.metahub.space/poster/small/tt11280740/img","description":"Mark leads a team.",
    "videos":[
    {"id":"tt11280740:2:1","name":"Hello, Ms. Cobel","season":2,"episode":1,"overview":"Season two opens."},
    {"id":"tt11280740:1:2","name":"Half Loop","season":1,"number":2,"description":"Second episode."},
    {"id":"tt11280740:0:11","name":"Sneak Peek","season":0,"number":11},
    {"id":"tt11280740:1:1","name":"Good News About Hell","season":1,"episode":1,"overview":"Mark is promoted."},
    {"id":"tt11280740:1:0","name":"Not an episode","season":1,"episode":0}
    ]}}
    """#

    @Test func parsesTorrentioStreamsAndMetadata() throws {
        let streams = try TorrentioClient.parseStreams(from: Data(Self.torrentioJSON.utf8))
        #expect(streams.count == 2)

        let first = try #require(streams.first)
        #expect(first.infoHash == "2a6b66671753c2454dd34115b72b0899514f0ca6")
        #expect(first.fileIdx == 1)
        #expect(first.filename == "Severance.S01E01.mkv")
        #expect(first.displayName == "Severance.S01E01.mkv")
        #expect(first.titleLine == "Severance.S01E01.mkv")
        #expect(first.quality == "4k DV | HDR10+")
        #expect(first.seeders == 78)
        #expect(first.sizeBytes == 12_036_645_847)
        #expect(first.provider == "Rutracker")
        #expect(first.trackers.count == 2)
        #expect(first.releaseName == "Severance.S01.2160p.WEB-DL")
        #expect(first.resolution == .uhd)
        #expect(first.isEpisodePack)
        #expect(!first.isMultiSeasonPack)

        let second = try #require(streams.last)
        #expect(second.titleLine == "Big Buck Bunny 1080p 30fps")
        #expect(second.quality == "1080p")
        #expect(second.seeders == 20)
        #expect(second.sizeBytes == 276_132_004)
        #expect(second.resolution == .fullHD)
        #expect(!second.isEpisodePack)
        #expect(second.provider == "MagnetDL")
        #expect(second.trackers.isEmpty)
    }

    @Test func magnetUsesScrapedTrackersAndEncodesDisplayName() throws {
        let streams = try TorrentioClient.parseStreams(from: Data(Self.torrentioJSON.utf8))
        let magnet = try #require(streams.first).magnetLink()

        #expect(magnet.hasPrefix("magnet:?xt=urn:btih:2a6b66671753c2454dd34115b72b0899514f0ca6&"))
        #expect(magnet.contains("dn=Severance.S01.2160p.WEB-DL"))
        #expect(magnet.contains("tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"))
        #expect(magnet.contains("tr=http%3A%2F%2Fbt.example.org%2Fann%3Fpasskey%3Dabc"))
        #expect(!magnet.contains("opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si"))

        let parsed = try MagnetLinkParser.parse(magnet)
        #expect(parsed.infoHash.hexString == "2a6b66671753c2454dd34115b72b0899514f0ca6")
        #expect(parsed.displayName == "Severance.S01.2160p.WEB-DL")
        #expect(parsed.trackers.count == 2)
    }

    @Test func magnetWithoutSourcesFallsBackToDefaultTrackers() throws {
        let streams = try TorrentioClient.parseStreams(from: Data(Self.torrentioJSON.utf8))
        let magnet = try #require(streams.last).magnetLink()

        #expect(magnet.contains("dn=bbb_sunflower_1080p_30fps_normal.mp4"))
        for tracker in TorrentioClient.defaultTrackers {
            let encoded = tracker.absoluteString
                .addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))
            #expect(magnet.contains("tr=\(encoded ?? tracker.absoluteString)"))
        }
    }

    @Test func magnetEscapesAmpersandsInDisplayName() throws {
        let json = #"""
        {"streams":[{"name":"Torrentio\n1080p","title":"Tom & Jerry\n👤 3 💾 700 MB ⚙️ EXT","infoHash":"88594aaacbde40ef3e2510c47374ec0aa396c08e","fileIdx":0,"behaviorHints":{"filename":"Tom & Jerry's Show.mkv"}}]}
        """#
        let stream = try #require(try TorrentioClient.parseStreams(from: Data(json.utf8)).first)
        let magnet = stream.magnetLink()
        #expect(magnet.contains("dn=Tom%20%26%20Jerry%27s%20Show.mkv"))
        #expect(try MagnetLinkParser.parse(magnet).displayName == "Tom & Jerry's Show.mkv")
    }

    @Test func prefersAFileNameOverTrailingAudioLine() throws {
        let json = #"""
        {"streams":[{"name":"Torrentio\n1080p","title":"The.Matrix.1999.1080p.BluRay.x264-GRP.mkv\n👤 86 💾 51.3 GB ⚙️ 1337x\nMulti Audio / 🇬🇧 / 🇮🇹","infoHash":"88594aaacbde40ef3e2510c47374ec0aa396c08e","fileIdx":0}]}
        """#
        let stream = try #require(try TorrentioClient.parseStreams(from: Data(json.utf8)).first)
        #expect(stream.titleLine == "The.Matrix.1999.1080p.BluRay.x264-GRP.mkv")
        #expect(stream.displayName == "The.Matrix.1999.1080p.BluRay.x264-GRP.mkv")
        #expect(stream.seeders == 86)
    }

    @Test func rejectsUnreadablePayloads() {
        #expect(throws: TorrentSearchError.invalidData) {
            try TorrentioClient.parseStreams(from: Data("not json".utf8))
        }
        #expect(throws: TorrentSearchError.invalidData) {
            try CinemetaClient.parseSearch(from: Data("not json".utf8), kind: .movie)
        }
    }

    @Test func parsesSearchResultsAndDropsDuplicates() throws {
        let results = try CinemetaClient.parseSearch(from: Data(Self.searchJSON.utf8), kind: .movie)
        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.id == "tt1254207")
        #expect(result.kind == .movie)
        #expect(result.name == "Big Buck Bunny")
        #expect(result.year == "2008")
        #expect(result.posterURL?.absoluteString == "https://images.metahub.space/poster/small/tt1254207/img")
    }

    @Test func parsesSeriesSeasonsWithoutSpecials() throws {
        let info = try CinemetaClient.parseSeries(from: Data(Self.seriesJSON.utf8))
        #expect(info.id == "tt11280740")
        #expect(info.name == "Severance")
        #expect(info.seasons.map(\.number) == [1, 2])

        let seasonOne = try #require(info.seasons.first)
        #expect(seasonOne.title == "Season 1")
        #expect(seasonOne.episodes.map(\.number) == [1, 2])
        #expect(seasonOne.episodes.first?.id == "tt11280740:1:1")
        #expect(seasonOne.episodes.first?.overview == "Mark is promoted.")
        #expect(seasonOne.episodes.last?.overview == "Second episode.")

        let seasonTwo = try #require(info.seasons.last)
        #expect(seasonTwo.episodes.first?.name == "Hello, Ms. Cobel")
    }

    @Test func singleEpisodeTorrentIsNotAPack() throws {
        let json = #"""
        {"streams":[{"name":"Torrentio\n720p","title":"The.Office.US.S01E01.720p.WEB\nThe.Office.US.S01E01.720p.WEB.mkv\n👤 5 💾 512 kB ⚙️ 1337x","infoHash":"88594aaacbde40ef3e2510c47374ec0aa396c08e","fileIdx":0,"behaviorHints":{"filename":"The.Office.US.S01E01.720p.WEB.mkv"}}]}
        """#
        let stream = try #require(try TorrentioClient.parseStreams(from: Data(json.utf8)).first)
        #expect(!stream.isEpisodePack)
        #expect(stream.sizeBytes == 524_288)
        #expect(stream.resolution == .hd)
    }

    @Test func detectsMultiSeasonPacks() throws {
        let json = #"""
        {"streams":[{"name":"Torrentio\n1080p","title":"The Office (US) (2005) Season 1-9 S01-S09 (1080p BluRay x265)\nSeason 1/The Office (US) (2005) - S01E01 - Pilot.mkv\n👤 399 💾 725.19 MB ⚙️ 1337x","infoHash":"88594aaacbde40ef3e2510c47374ec0aa396c08e","fileIdx":0,"behaviorHints":{"filename":"The Office (US) (2005) - S01E01 - Pilot.mkv"}}]}
        """#
        let stream = try #require(try TorrentioClient.parseStreams(from: Data(json.utf8)).first)
        #expect(stream.isEpisodePack)
        #expect(stream.isMultiSeasonPack)
    }

    @Test func searchSectionsPutTheBestTopMatchFirst() {
        let movie = MediaSearchResult(id: "tt1", kind: .movie, name: "The Office Wife", year: "1930", posterURL: nil)
        let show = MediaSearchResult(id: "tt2", kind: .series, name: "The Office", year: "2005", posterURL: nil)
        let results = MediaSearchResults(movies: [movie], series: [show])
        #expect(results.sections(query: "the office").map(\.kind) == [.series, .movie])
        #expect(results.sections(query: "the office wife").map(\.kind) == [.movie, .series])
        #expect(results.sections(query: "office").map(\.kind) == [.series, .movie])
        #expect(MediaSearchResults(movies: [movie], series: []).sections(query: "x").map(\.kind) == [.movie])
    }
}
