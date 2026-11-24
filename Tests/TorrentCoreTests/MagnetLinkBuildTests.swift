import Foundation
import Testing
import TorrentCore

@Suite struct MagnetLinkBuildTests {
    @Test func builtLinkRoundTripsThroughParser() throws {
        let infoHash = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
        let name = "Tom & Jerry + Friends=Best?.mkv"
        let trackers = [
            URL(string: "http://bt.example.org/announce?passkey=abc&uid=7")!,
            URL(string: "udp://tracker.opentrackr.org:1337/announce")!,
            URL(string: "udp://tracker.opentrackr.org:1337/announce")!,
        ]
        let magnet = MagnetLink.build(infoHash: infoHash, displayName: name, trackers: trackers)
        let parsed = try MagnetLinkParser.parse(magnet)
        #expect(parsed.infoHash.hexString == infoHash)
        #expect(parsed.displayName == name)
        #expect(parsed.trackers == Array(trackers.prefix(2)))
    }

    @Test func omitsDisplayNameWhenAbsent() throws {
        let magnet = MagnetLink.build(infoHash: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", displayName: nil, trackers: [])
        #expect(magnet == "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
        #expect(try MagnetLinkParser.parse(magnet).displayName == nil)
    }
}

