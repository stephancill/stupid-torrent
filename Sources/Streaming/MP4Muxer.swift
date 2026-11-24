import Foundation

enum TransmuxCodec: Equatable, Sendable {
    case h264
    case hevc
    case aac
    case eac3
    case ac3
    case alac
}

struct TransmuxTrack: Sendable {
    var trackId: Int
    var timescale: Int
    var codec: TransmuxCodec
    var codecPrivate: Data?
    var audioConfig: Data?
    var width: Int?
    var height: Int?
    var channels: Int
    var sampleRate: Double
    var bitDepth: Int
    var language: String?

    var isVideo: Bool {
        codec == .h264 || codec == .hevc
    }
}

struct TransmuxSample: Sendable {
    var data: Data
    var durationTicks: Int64
    var decodeTimeTicks: Int64
    var compositionOffsetTicks: Int64
    var isKeyframe: Bool
}

enum MP4Muxer {
    static func initSegment(tracks: [TransmuxTrack]) -> Data {
        var data = Data()
        data.append(ftyp())
        data.append(moov(tracks: tracks))
        return data
    }

    private static func ftyp() -> Data {
        var payload = Data()
        payload.append(contentsOf: "isom".utf8)
        payload.append(u32(0))
        payload.append(contentsOf: "isom".utf8)
        payload.append(contentsOf: "iso6".utf8)
        payload.append(contentsOf: "mp41".utf8)
        return box("ftyp", payload)
    }

    private static func moov(tracks: [TransmuxTrack]) -> Data {
        var payload = Data()
        payload.append(mvhd(nextTrackId: (tracks.map(\.trackId).max() ?? 0) + 1))
        for track in tracks {
            payload.append(trak(track: track))
        }
        payload.append(mvex(tracks: tracks))
        return box("moov", payload)
    }

    private static func mvhd(nextTrackId: Int) -> Data {
        var payload = Data()
        payload.append(u32(0))
        payload.append(u32(0))
        payload.append(u32(1000))
        payload.append(u32(0))
        payload.append(u32(0x00010000))
        payload.append(u16(0x0100))
        payload.append(Data(repeating: 0, count: 10))
        payload.append(identityMatrix())
        payload.append(Data(repeating: 0, count: 24))
        payload.append(u32(UInt32(nextTrackId)))
        return fullBox("mvhd", version: 0, flags: 0, payload)
    }

    private static func trak(track: TransmuxTrack) -> Data {
        var payload = Data()
        payload.append(tkhd(track: track))
        payload.append(mdia(track: track))
        return box("trak", payload)
    }

    private static func tkhd(track: TransmuxTrack) -> Data {
        var payload = Data()
        payload.append(u32(0))
        payload.append(u32(0))
        payload.append(u32(UInt32(track.trackId)))
        payload.append(u32(0))
        payload.append(u32(0))
        payload.append(Data(repeating: 0, count: 8))
        payload.append(u16(0))
        payload.append(u16(0))
        payload.append(u16(track.isVideo ? 0 : 0x0100))
        payload.append(u16(0))
        payload.append(identityMatrix())
        if let width = track.width, let height = track.height {
            payload.append(u32(UInt32(clamping: width) << 16))
            payload.append(u32(UInt32(clamping: height) << 16))
        } else {
            payload.append(u32(0))
            payload.append(u32(0))
        }
        return fullBox("tkhd", version: 0, flags: 0x7, payload)
    }

    private static func mdia(track: TransmuxTrack) -> Data {
        var payload = Data()
        payload.append(mdhd(track: track))
        payload.append(hdlr(handlerType: track.isVideo ? "vide" : "soun", name: track.isVideo ? "VideoHandler" : "SoundHandler"))
        payload.append(minf(track: track))
        return box("mdia", payload)
    }

    private static func mdhd(track: TransmuxTrack) -> Data {
        var payload = Data()
        payload.append(u32(0))
        payload.append(u32(0))
        payload.append(u32(UInt32(track.timescale)))
        payload.append(u32(0))
        payload.append(u16(languageCode(track.language)))
        payload.append(u16(0))
        return fullBox("mdhd", version: 0, flags: 0, payload)
    }

    private static func hdlr(handlerType: String, name: String) -> Data {
        var payload = Data()
        payload.append(u32(0))
        payload.append(contentsOf: handlerType.utf8)
        payload.append(Data(repeating: 0, count: 12))
        payload.append(contentsOf: name.utf8)
        payload.append(u8(0))
        return fullBox("hdlr", version: 0, flags: 0, payload)
    }

    private static func minf(track: TransmuxTrack) -> Data {
        var payload = Data()
        if track.isVideo {
            var vmhd = Data()
            vmhd.append(u16(0))
            vmhd.append(Data(repeating: 0, count: 6))
            payload.append(fullBox("vmhd", version: 0, flags: 1, vmhd))
        } else {
            var smhd = Data()
            smhd.append(u16(0))
            smhd.append(u16(0))
            payload.append(fullBox("smhd", version: 0, flags: 0, smhd))
        }
        payload.append(dinf())
        payload.append(stbl(track: track))
        return box("minf", payload)
    }

    private static func dinf() -> Data {
        let urlBox = fullBox("url ", version: 0, flags: 1, Data())
        let dref = fullBox("dref", version: 0, flags: 0, u32(1) + urlBox)
        return box("dinf", dref)
    }

    private static func stbl(track: TransmuxTrack) -> Data {
        var payload = Data()
        payload.append(stsd(track: track))
        payload.append(emptyTable("stts"))
        payload.append(emptyTable("stsc"))
        payload.append(emptyTable("stsz"))
        payload.append(emptyTable("stco"))
        return box("stbl", payload)
    }

    private static func emptyTable(_ type: String) -> Data {
        if type == "stsz" {
            return fullBox(type, version: 0, flags: 0, u32(0) + u32(0))
        }
        return fullBox(type, version: 0, flags: 0, u32(0))
    }

    private static func stsd(track: TransmuxTrack) -> Data {
        var payload = Data()
        payload.append(u32(1))
        payload.append(sampleEntry(track: track))
        return fullBox("stsd", version: 0, flags: 0, payload)
    }

    private static func mvex(tracks: [TransmuxTrack]) -> Data {
        var payload = Data()
        for track in tracks {
            var trex = Data()
            trex.append(u32(UInt32(track.trackId)))
            trex.append(u32(1))
            trex.append(u32(0))
            trex.append(u32(0))
            trex.append(u32(0))
            payload.append(fullBox("trex", version: 0, flags: 0, trex))
        }
        return box("mvex", payload)
    }

    private static func identityMatrix() -> Data {
        var data = Data()
        data.append(u32(0x00010000))
        data.append(u32(0))
        data.append(u32(0))
        data.append(u32(0))
        data.append(u32(0x00010000))
        data.append(u32(0))
        data.append(u32(0))
        data.append(u32(0))
        data.append(u32(0x40000000))
        return data
    }

    private static func sampleEntry(track: TransmuxTrack) -> Data {
        switch track.codec {
        case .h264, .hevc:
            return videoSampleEntry(track: track)
        case .aac, .eac3, .ac3, .alac:
            return audioSampleEntry(track: track)
        }
    }

    private static func videoSampleEntry(track: TransmuxTrack) -> Data {
        var payload = Data()
        payload.append(Data(repeating: 0, count: 6))
        payload.append(u16(1))
        payload.append(u16(0))
        payload.append(u16(0))
        payload.append(Data(repeating: 0, count: 12))
        payload.append(u16(UInt16(clamping: track.width ?? 0)))
        payload.append(u16(UInt16(clamping: track.height ?? 0)))
        payload.append(u32(0x00480000))
        payload.append(u32(0x00480000))
        payload.append(u32(0))
        payload.append(u16(1))
        payload.append(compressorname(""))
        payload.append(u16(0x0018))
        payload.append(u16(0xFFFF))
        if let config = track.codecPrivate {
            payload.append(box(track.codec == .h264 ? "avcC" : "hvcC", config))
        }
        return box(track.codec == .h264 ? "avc1" : "hvc1", payload)
    }

    private static func audioSampleEntry(track: TransmuxTrack) -> Data {
        let isDolby = track.codec == .eac3 || track.codec == .ac3
        var payload = Data()
        payload.append(Data(repeating: 0, count: 6))
        payload.append(u16(1))
        payload.append(u16(0))
        payload.append(u16(0))
        payload.append(u32(0))
        payload.append(u16(isDolby ? 2 : UInt16(clamping: track.channels)))
        payload.append(u16(isDolby ? 16 : UInt16(clamping: track.bitDepth)))
        payload.append(u16(0))
        payload.append(u16(0))
        payload.append(u32(UInt32(clamping: Int(track.sampleRate.rounded())) << 16))
        switch track.codec {
        case .aac:
            payload.append(esds(audioSpecificConfig: track.codecPrivate))
            return box("mp4a", payload)
        case .eac3:
            payload.append(box("dec3", track.audioConfig ?? Data()))
            return box("ec-3", payload)
        case .ac3:
            payload.append(box("dac3", track.audioConfig ?? Data()))
            return box("ac-3", payload)
        case .alac:
            payload.append(fullBox("alac", version: 0, flags: 0, track.codecPrivate ?? Data()))
            return box("alac", payload)
        case .h264, .hevc:
            return Data()
        }
    }

    private static func compressorname(_ name: String) -> Data {
        var data = Data()
        let bytes = Array(name.utf8).prefix(31)
        data.append(u8(UInt8(bytes.count)))
        data.append(contentsOf: bytes)
        data.append(Data(repeating: 0, count: 31 - bytes.count))
        return data
    }

    private static func languageCode(_ language: String?) -> UInt16 {
        let letters = Array((language ?? "").lowercased().utf8)
        guard letters.count == 3, letters.allSatisfy({ (0x61...0x7A).contains($0) }) else { return 0x55C4 }
        return letters.reduce(0) { ($0 << 5) | UInt16($1 - 0x60) }
    }

    static func esds(audioSpecificConfig: Data?) -> Data {
        let asc = audioSpecificConfig ?? Data()
        let slConfig: [UInt8] = [0x02]
        var decSpecific = Data()
        decSpecific.append(0x05)
        decSpecific.append(descriptorLength(asc.count))
        decSpecific.append(asc)
        var decoderConfig = Data()
        decoderConfig.append(0x40)
        decoderConfig.append(0x15)
        decoderConfig.append(u24(0))
        decoderConfig.append(u32(0))
        decoderConfig.append(u32(0))
        decoderConfig.append(decSpecific)
        var es = Data()
        es.append(u16(0))
        es.append(u8(0))
        es.append(0x04)
        es.append(descriptorLength(decoderConfig.count))
        es.append(decoderConfig)
        es.append(0x06)
        es.append(descriptorLength(slConfig.count))
        es.append(contentsOf: slConfig)
        var payload = Data()
        payload.append(0x03)
        payload.append(descriptorLength(es.count))
        payload.append(es)
        return fullBox("esds", version: 0, flags: 0, payload)
    }

    static func descriptorLength(_ count: Int) -> Data {
        var bytes: [UInt8] = []
        var value = count
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if !bytes.isEmpty { byte |= 0x80 }
            bytes.insert(byte, at: 0)
        } while value > 0
        return Data(bytes)
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(u32(UInt32(payload.count + 8)))
        data.append(contentsOf: type.utf8)
        data.append(payload)
        return data
    }

    static func fullBox(_ type: String, version: UInt8, flags: UInt32, _ payload: Data) -> Data {
        var head = Data()
        head.append(u8(version))
        head.append(u24(flags & 0xFFFFFF))
        return box(type, head + payload)
    }

    static func u8(_ value: UInt8) -> Data {
        Data([value])
    }

    static func u16(_ value: UInt16) -> Data {
        var data = Data(capacity: 2)
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
        return data
    }

    static func u24(_ value: UInt32) -> Data {
        var data = Data(capacity: 3)
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
        return data
    }

    static func u32(_ value: UInt32) -> Data {
        var data = Data(capacity: 4)
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
        return data
    }

    static func u64(_ value: UInt64) -> Data {
        var data = Data(capacity: 8)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
        return data
    }
}
