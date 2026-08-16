import Testing
import Foundation
import AVFoundation
@testable import Streaming
import TorrentTestingSupport

/// End-to-end hermetic gate for the MKV → fMP4 transmuxer: parse a fixture's head, remux every
/// cluster into fragments, validate the resulting fMP4 structurally and with AVFoundation
/// (macOS host can load AVURLAsset from a file), and cross-check box layout.
@Suite struct MKVTransmuxTests {

    private let fixtures = [
        ("h264-aac.mkv", 3.0),
        ("h264-bframes.mkv", 3.0),
        ("hevc-main10.mkv", 3.0),
        ("eac3.mkv", 3.0),
        ("ac3.mkv", 3.0),
    ]

    /// Remuxes a full in-memory MKV into a complete fragmented MP4.
    private func remuxFull(_ data: Data) throws -> Data {
        let info = try MatroskaParser.parseHead(bytes: data)
        #expect(!info.tracks.isEmpty)
        let remuxer = try MKVRemuxer(info: info)
        #expect(remuxer.hasMedia)

        var out = remuxer.initSegment()
        var fragmentsEmitted = 0
        var offset = info.firstClusterOffset ?? 0
        let segmentEnd = info.segmentDataEnd ?? data.count
        while offset < segmentEnd, offset < data.count {
            if let range = try MatroskaParser.readClusterRange(bytes: data, offset: offset) {
                let cluster = try MatroskaParser.parseCluster(bytes: range.bytes, segmentDataStart: 0)
                if let fragment = try remuxer.consume(cluster) {
                    out.append(fragment)
                    fragmentsEmitted += 1
                }
                offset = range.elementEnd
            } else {
                break
            }
        }
        #expect(fragmentsEmitted > 0)
        return out
    }

    @Test func parsesHeadAndBuildsInitSegment() throws {
        for (name, _) in fixtures {
            let data = try Fixtures.data(named: "mkv/\(name)")
            let info = try MatroskaParser.parseHead(bytes: data)
            #expect(info.firstClusterOffset != nil, "\(name): no first cluster")
            #expect(info.tracks.contains { $0.trackType == 1 }, "\(name): no video track")
            let remuxer = try MKVRemuxer(info: info)
            let initSegment = remuxer.initSegment()
            // ftyp + moov with per-track sample entries.
            #expect(initSegment.prefix(4) == Data([0, 0, 0, 0x1C])) // ftyp size (28)
            #expect(initSegment.dropFirst(4).prefix(4) == Data("ftyp".utf8))
            #expect(remuxer.tracks.allSatisfy { $0.trackId >= 1 })
        }
    }

    @Test func remuxesToPlayableFragmentedMP4() async throws {
        for (name, expectedDuration) in fixtures {
            let data = try Fixtures.data(named: "mkv/\(name)")
            let fmp4 = try remuxFull(data)
            #expect(!fmp4.isEmpty, "\(name): empty remux")

            // Structural sanity: init segment + at least one moof, and no trailing zeros.
            #expect(fmp4.range(of: Data("moof".utf8)) != nil, "\(name): no moof")
            #expect(fmp4.range(of: Data("sidx".utf8)) == nil, "\(name): no sidx expected yet")

            // Write to a temp file and load with AVFoundation (macOS host).
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("transmux-\(UUID().uuidString).mp4")
            try fmp4.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let asset = AVURLAsset(url: url)
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            #expect(playable, "\(name): AVAsset not playable")
            let seconds = CMTimeGetSeconds(duration)
            #expect(seconds > expectedDuration - 0.5 && seconds < expectedDuration + 0.5,
                    "\(name): duration \(seconds) != ~\(expectedDuration)s")

            // Each fixture must keep its video + audio tracks, and both must actually decode.
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(videoTracks.count == 1, "\(name): expected 1 video track")
            #expect(audioTracks.count == 1, "\(name): expected 1 audio track")
            for track in videoTracks + audioTracks {
                let format = try await track.load(.formatDescriptions).first
                #expect(format != nil, "\(name): track without format description")
            }

            // Ground truth: AVAssetReader must be able to pull samples for both tracks.
            let reader = try AVAssetReader(asset: asset)
            for (kind, tracks) in [("video", videoTracks), ("audio", audioTracks)] {
                guard let track = tracks.first else { continue }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                #expect(reader.canAdd(output), "\(name): can't add \(kind) output")
                reader.add(output)
            }
            #expect(reader.startReading(), "\(name): reader failed \(String(describing: reader.error))")
            for _ in 0..<4 {
                _ = reader.outputs.compactMap { ($0 as? AVAssetReaderTrackOutput)?.copyNextSampleBuffer() }
            }
            reader.cancelReading()
            #expect(reader.status != .failed, "\(name): reader failed decoding: \(String(describing: reader.error))")
        }
    }

    @Test func blockTimestampsArePresentationTimes() throws {
        // h264-bframes has B-frames, so presentation order differs from decode order.
        let data = try Fixtures.data(named: "mkv/h264-bframes.mkv")
        let info = try MatroskaParser.parseHead(bytes: data)
        let videoTrack = info.tracks.first { $0.trackType == 1 }
        #expect(videoTrack != nil)

        // Iterate the first cluster and check that block PTS values are out of presentation
        // order (they are PTS in decode order, so NOT monotonic as stored with B-frames).
        var psts: [Int64] = []
        if let range = try MatroskaParser.readClusterRange(bytes: data, offset: info.firstClusterOffset!) {
            let cluster = try MatroskaParser.parseCluster(bytes: range.bytes, segmentDataStart: 0)
            for block in cluster.blocks {
                psts.append(Int64(cluster.timestamp) + block.relativeTimestamp)
            }
        }
        let sorted = psts.sorted()
        #expect(psts.count > 4)
        #expect(psts != sorted, "B-frame fixture should be out of presentation order")
    }

    @Test func selectsOnlyDefaultAudioTrack() throws {
        var disabled = MKVTrack(number: 1, trackType: 2)
        disabled.codecID = "A_AAC"
        disabled.codecPrivate = Data([0x12, 0x10])
        disabled.channels = 8
        disabled.isDefault = true
        disabled.isEnabled = false

        var commentary = MKVTrack(number: 2, trackType: 2)
        commentary.codecID = "A_AAC"
        commentary.codecPrivate = Data([0x12, 0x10])
        commentary.channels = 2
        commentary.isDefault = false

        var primary = MKVTrack(number: 3, trackType: 2)
        primary.codecID = "A_AAC"
        primary.codecPrivate = Data([0x12, 0x10])
        primary.channels = 6
        primary.isDefault = true

        var info = MatroskaInfo()
        info.tracks = [disabled, commentary, primary]
        let remuxer = try MKVRemuxer(info: info)

        #expect(remuxer.tracks.count == 1)
        #expect(remuxer.tracks.first?.channels == 6)
    }

    /// EBML-laced AAC frames must be sliced at the correct boundaries and spaced by the track's
    /// default duration. Regression: laced frame sizes were computed with a broken VINT width
    /// (keyed off the last byte's MSB instead of the first byte's leading-1 marker) and a signed
    /// delta offset off by two, collapsing frames onto one timestamp / shifting every AAC frame.
    /// The payloads are real blocks from a 10-bit x265 WEBRip (48 kHz AAC 5.1, 8 frames/block).
    @Test func expandsEbmlLacedAACFrames() throws {
        let hexA = "07aabec3bfc2bec0de02004c61766336322e32382e313031000230400211004608c0463508c0fac3787d421001b58460001c00de3503ea1080524108d42303eb0e41f508400888c6a0de1f5084012c34700fa842009468c230000e00de3503ea108033c68423506f0fa842009468de1f5084008c48c6a0e21f50840089c03ea1080251308c00038000e03503ea108024e242350700fa842006c3787d4210011231a83787d421005b0d1bc3ea1080251ecc230000e000e03503ea108011a108d41bc3ea10802d1a3787d4210094a34231a83787d421004a3d9bc3ea10801868c1c4011040b800dc3503ea108025a3b108d41bc3ea10801da8de1f508400508c6a0de1f508401299bc3ea108032c4c1c8011040b8000da3503ea108025b31108d41bc3ea1080251a3787d42100254231a83807d42100146e0fa84200961f9b0720044102e000dc3503ea108025f6de423506f0fa8420046ce01f508400e54231a83787d421004b955ac3ea308035fc7ef30720044102e0"
        let hexB = "07b1c0bdc0be609a61ac00de3503ea1080251a108d41b83ea10804a5d3b3787d421004bd54231a83707d421006b8c1bc3ea108032e1a308c00038000d83503ea30805f8fd57a7108d41b43ea108025eba3687d421004bf8d08c6a0de1f5084012c346f0fa8420061ab08c0003800dc3503ea10803bbc8423506f0fa84200961e2e21f508400888c6a0da1f5184019ffaebb787d421004a3cd8460001c000da3503ea108032f6de42350710fa842004a8da1f518402737bc231a83787d4210023bdb03ea308033ff59ba61180007000e03503ea1080256a108d41bc3ea108025a2ade1f5084017888c6a0dc1f5084019f9766c0fa8c200af1f798460001c000a0350296209885ff3fff980e3968230a60887024f4ba6c7f8721470c430d473be1c9e9b4a4b0220748f6211a828052c41310bfe7fff301c72d04614c1116049e974d8ff0e428e18861a8e77c393d369496044097ab8a8052c41310bfe7fff3077c3e38902478dc84bc010b1038a29d2623f6d623fbb0658f1231a828056822109085fdff6070f67caea5e89704e2c0478a8052c61210bfcffe9ff8137d370aee0c714b93c9ea89f03e304f9071c27c3f7a4f4b87c7d048427d431ddf079eedb879f01016a518460001c000e435082092100902021159604a107085ed7727e3f9f3fdf7e277f60479d5e41cc7f4fb8f1e26eea612a7779381109c3884e5422709963368b191d96048607064b0f892703324f84f1327734043217096aaedb75edb74fbad4921c0cf721645bca417f431d99f2f362339c0693a2e9e95c56f1c57d4b91c0f567a600024f0d0846a0e4410490c02c101986c74230c04c20e30bdadd3f5ff7d7fe8f9e3d780479d5f3930c9a5143ce7f0f844951ab5cf64f0f9a279acd13d4e4c9e4b0a4b11009cc511e67bb21abd812e2181279fd793def062713a7f3292e83b59fbf9f9356310045daf1db8eb569ab581a48720f0bfb69a7c171c55e4cf6c604bee2f10013f8527220839820280806c8c21083842fd7e3ff2dfe9cf8df7ee094b28493dab15432239642240259fc0110e748e5e712c7ee4858bc46f402730c4c7449e3b5c4f342266a4423677ad35a61ffc3fc3d7df10fba4232bc75badcd971dcd54d85edff5a50b33cf32b9b7d24611736fa6ea7f4009548c6a0e441019040c41011040702b2284202179d4fbebfc7b7f4e7f6f90577811feca5960b3f6eba60012f2c9b9a4d4799c7930e40e520a9e439672021b56933628854ba4b539c2780a6472b9d9fb1a4000d6bf1f48d4e2fc87dffc9a55037bdd2fb8068b8df7e6b4c6e80d6b40b468e641010840c4101a040502b2c09020e10b8eb5ed3e3fd1fc77eb5f3ee0a3194000c3141eab6a62c74cb9795c1e25aa7a736cd884315431e60c9ef6a12d9848e6300435bc3c8e12111c5512184ab957a213e3196213524f0b28869b8e5a83d115c9b2aa6d62f7e4a8bcecfa1459136dd8b0e7e556a1724812e7a8d23684b636fbbb7b8d623578f0e7d1cef0078787addc0ed46118000700c0352f14984be7ebed5ede38bf7fbf3d5fdbe177edfe9f9ef7e04c1cde50ad82788be4e69db8e526527173a109e767363a1816145d71c61028e9e274dada31c45d035afa463c077244dcd1434c48b9bf04db920c670aa6165cea3399be2e7d8db736628b0c24d2c26d964e74197c1a1707613e6fd1494ec690d6ed09e16292dbe2c871fed2430d108be89385609b1c4d22cece210ef90bf88210539d44b7e8bb81a2b416740cca0ca3adf59fd2fd8f2c6000a0019a5ed9a21d0754b8386091b57b54ae173edd5ae349182c637f06ddce13d53844b9ded795bf8d21607c2112d26438e650b07afe57a6f54f3cca23271657f2bc07a229b3aace36c587c83e6c74d089af07e6d71030983daf8de0bca3d800b9d5679828f01dd1e181686c17880531f37caf919fa292c0ce15bff7f78210b2ea9943772d231a19631b7573e0a80b705410aa1dc6e2253dbe3be1a756db636d29908980b69703588cf2c631a904182139e371d400000c54544c20c36db1a74f2f1db6db6db3b0f53c73a14368437bf5c4132a9b73e0da4c972aa2237969442632109744b53705088bcb7d6de3c2597088cdbe4a8185f6d6e211a8355fc143643ef3edd679febe77ed5edf9fd52f5d7993fb4655ef5cd6bd4c991b1aec984c4f2582a9a1908902d146cf5a88fdce42ee0f2d26222f48f09cc10a7241129f76361cf9ac4b8f8bc62871b3071a7f008217521fcd7b0ff818f0bab7c1f5c7866f3c9e0fedf61befe91cb96f83dad15a65276e6795103b488884e04926d65ba89fe1139cdb1a812448212e711af789d9e1a4f2db4276b2a4f379d27a701089c1c871de604397f02239c8c4294a2333124e66009e83484f332c9d8a3995e1c91e365deb6e886e45f1bd9e87e975383827ed35451ff6f260113293dafb537c639e28bc79afaebcd260e33c5f306c854b03d635a28bae33d2785a68c33e7644803b91c1a2fd7e3e70587d870f9becbdd1f3105897f73a373b928b0db812030ea8764f0e5d8f1bb02c3b1656f0f90a40be38d25c1737ec3ca3d25b03bc34a6c18b71e7b0ecfd9fe51620775e8fbb67a6ea7c7ee45b03198d98c4ee8522897c1ea4d74f86ba8a0f6b7f0cdccfc8f80c619c5bd7aa7de758ea98cc1fa3e86e8857efffdd59648a3100aaa317f45596ccdfbfa9bc7a120465385d94f086abd9e354216537f5fdcb01bfff7c4c6eca0a0e579e74e48d7532ac0f1e51b39657dd3149d7a9b2af45de5f2c2ccffd49dfb0b28c92d467942e9aa1cdaaf8c1a2c21f7fb4adebcfa9f5ccf3efd579d71fcf3ebc7ad2bc74ddd56642a87783f499584d445b46d67920a38236ba6d5c0448728ff5bd6eb6c6eb3e6b1b5ada7cffeb7ebfdaeb6c8e3375a8530f991e2eb68b8c36634d3ee2cf9f319a20b8384994b778ab60906c1e1104d106cf6100348740e24465e689f16e2c4f836389cb90431f6086ab26475126cd853fce213f24425482182d890e2dcb085ba6414126c804e74827064138d4ab3844245f20f5d1008fb0cde393d3d5d742aec1fbc4472076dab4523d84c0ee7fc5eaaca11dfd4f8be7bd8fec7a6e3f87ab4f11a44ecb8fa0d254d8b3d27ff3f8b756e0ed4e6c80f71fd4fd7f35ad3a2734dce0b98c4599ca377966f28e12dfc6debb05a2bf6393b66819935f06abedf95f6613fd9e78fbd6f318e9cbffe9ffc63e70d20d751c7cf9b72e17e2dad89ad7f5f37ca37ce3aaf83dd3e33bee3d53df2be87b27f732cc9e579df57a7785003027278fa875485eeebf61dc6d36988f0c177edc74db3a6db6741860d77b79e9e5ede78c67018141808d41a73c407206bbdbc7a15040169b6de5c7a1113ab9e5b62a111243b449136f6971d2b3d19a6586c75f6ecce3ab618b6f7eedfc112c2d102003315e46b2f154c658f231221db4a12e5118d419af1488430482f7fdfe6f9f399ece3c6a3897edd573e3c32f24accd7777b9cf6081cf76112afce872092b61dee3721c358ddeef83adb2ee0aa345f75d96821bf464c4626414c67982093c4f0e06371b7b447704699ff1deac2063903078831b5c66da9a78d930089985f8ff5420305101ffe938d2ac6190746210e010870c84f864706f277b544f416ae8c890c764c8528b8f14440926dba4ece12839c42660c85b3132dc2677f22cb27ac195818884a4c89c0a07eb2591da64264272ff487de3922c0dd0b19af909c6960b85556b49c8c612138a0e4f3ecb8e46182079356788d1451f57d7e01f1dcce038c58272314185136cf8bad84ed7bc3e276e79d144cd5884276f3272c03b7d572541d7232e97754958285c4f05556dccff57d9dcf2592b0ea919e86b7aa5a0d585bb683a2eb8f3a5ddc7da54f4a8913ad6450726db65b9ce4e9cf3816d888a6580c391b498000287037147e7d7c88976d8c63380c9b6770c633a130c34db3828544c33756d890a8da45e1fdbd7caee22016db6dd5cf5301ab8e810e40875dd7c405977b22a31254d63b0d65d97971e0452a95a4b0dcc36d56d20ab351ad05e06f562b1c3acf4961a0d86f5edef39f3bf3ebdaa737a7b5f1fbd7e79f1370a4e665777acd894e593ab2b3762951889a0755b4b1c7006de8109cefe84d5f3f81582c8b4a77f219aba531cb3b8b95918863275656456492c3917b8df7e1498924d45e2bb97f2f3dd685b320930271f97260a5d293a3ad2795c093b95c9d6c8132b8848a576ec49ae810cd9c8d519336809c79e42d51996eea2ba20908312651135b71fabd7af6ed87e1319adf27f5baa29dedcce80e48c5e3dc96cab82d9cdbcfb7f5b998822c9df2f3061b883366291c0451433494f71f3271a48580cb708e0d2671606964ac57f1e334507443b7194023b39f9f9f566cdb3daef71af0e23f2128a42db1c7c6c9374c85763deb288c695c0604f98cdeaf15c5555194a6b63e5fb759c9a4bac84edcddd9f2b7aec1c63a09422aad9d2bf2d0a1678d506372767428bbf6eabfc73b337efc9accc60d4b26ff81f37d1e1e1e1eb7777b180f0f83607540e3f7f40fc42bb917f5c3a25d336ea65b913352bea16c90839819da862ae096b0b2b0700088260fff6be"

        let cases: [(String, [Int], Double)] = [
            (hexA, [42, 41, 45, 45, 48, 47, 48, 50], 21.33),
            (hexB, [49, 50, 48, 49, 48, 203, 632, 2186], 21.33),
        ]
        for (hex, expectedSizes, frameTicks) in cases {
            let data = Data(hexToBytes(hex))
            let block = MKVBlock(
                trackNumber: 2,
                relativeTimestamp: 0,
                isKeyframe: false,
                lacing: .ebml,
                data: data
            )
            let frames = try #require(MatroskaParser.expandLacing(block, frameDurationTicks: frameTicks))
            #expect(frames.count == expectedSizes.count)
            let sizes = frames.map { $0.data.count }
            #expect(sizes == expectedSizes)
            // Frames within a laced block must advance by the track default duration (no collapses).
            let expectedOffsets = frames.indices.map { Int64((frameTicks * Double($0)).rounded()) }
            #expect(frames.map { $0.relativeTimestamp } == expectedOffsets)
        }
    }

    private func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
}
