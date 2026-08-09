import Foundation

/// The codecs the transmuxer can carry into fragmented MP4.
public enum TransmuxCodec: Equatable, Sendable {
    case h264
    case hevc
    case aac
    case eac3
    case ac3
    case alac
    case unknown
}

/// A track the fMP4 muxer emits. `timescale` is ticks per second of the virtual movie; for MKV
/// input it is `1_000_000_000 / timestampScaleNs` so MKV timestamp ticks map 1:1 (no rounding).
public struct TransmuxTrack: Sendable {
    public var trackId: Int
    public var timescale: Int
    public var codec: TransmuxCodec
    /// The ISO decoder-config record (`avcC`/`hvcC`/AudioSpecificConfig/alac cookie).
    public var codecPrivate: Data?
    /// Pre-built `dec3`/`dac3` box payload for E-AC-3/AC-3 tracks.
    public var audioConfig: Data?
    public var width: Int?
    public var height: Int?
    public var channels: Int
    public var sampleRate: Double
    public var bitDepth: Int
    public var language: String?
    /// Total duration in this track's timescale ticks (drives mvhd/mdhd/tkhd).
    public var durationTicks: Int64

    public var isVideo: Bool {
        codec == .h264 || codec == .hevc
    }

    public init(
        trackId: Int,
        timescale: Int,
        codec: TransmuxCodec,
        codecPrivate: Data?,
        audioConfig: Data? = nil,
        width: Int? = nil,
        height: Int? = nil,
        channels: Int = 2,
        sampleRate: Double = 48000,
        bitDepth: Int = 16,
        language: String? = nil,
        durationTicks: Int64 = 0
    ) {
        self.trackId = trackId
        self.timescale = timescale
        self.codec = codec
        self.codecPrivate = codecPrivate
        self.audioConfig = audioConfig
        self.width = width
        self.height = height
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.language = language
        self.durationTicks = durationTicks
    }
}

/// One muxed sample in a fragment.
public struct TransmuxSample: Sendable {
    public var data: Data
    public var durationTicks: Int64
    public var decodeTimeTicks: Int64
    /// Presentation time minus decode time, in track ticks (usually 0 for audio).
    public var compositionOffsetTicks: Int64
    public var isKeyframe: Bool

    public init(
        data: Data,
        durationTicks: Int64,
        decodeTimeTicks: Int64,
        compositionOffsetTicks: Int64 = 0,
        isKeyframe: Bool = true
    ) {
        self.data = data
        self.durationTicks = durationTicks
        self.decodeTimeTicks = decodeTimeTicks
        self.compositionOffsetTicks = compositionOffsetTicks
        self.isKeyframe = isKeyframe
    }
}

public enum MP4Error: Error, CustomStringConvertible {
    case unsupportedCodec(String)
    case invalidState(String)

    public var description: String {
        switch self {
        case .unsupportedCodec(let c): "unsupported codec: \(c)"
        case .invalidState(let s): "invalid state: \(s)"
        }
    }
}

/// ISO/IEC 14496-12 box writer for fragmented MP4, sufficient for AVPlayer playback.
public enum MP4Muxer {

    // MARK: - Init segment

    public static func initSegment(tracks: [TransmuxTrack]) -> Data {
        var data = Data()
        data.append(ftyp())
        data.append(moov(tracks: tracks))
        return data
    }

    public static func ftyp() -> Data {
        var payload = Data()
        payload.append(contentsOf: "isom".utf8)
        payload.append(u32(0))
        payload.append(contentsOf: "isom".utf8)
        payload.append(contentsOf: "iso6".utf8)
        payload.append(contentsOf: "mp41".utf8)
        return box("ftyp", payload)
    }

    public static func moov(tracks: [TransmuxTrack]) -> Data {
        let timescale = tracks.first?.timescale ?? 1000
        let duration = tracks.map { Int($0.durationTicks) }.max() ?? 0

        var payload = Data()
        payload.append(mvhd(timescale: timescale, duration: duration, nextTrackId: (tracks.map(\.trackId).max() ?? 0) + 1))
        for track in tracks {
            payload.append(trak(track: track))
        }
        payload.append(mvex(tracks: tracks))
        return box("moov", payload)
    }

    private static func mvhd(timescale: Int, duration: Int, nextTrackId: Int) -> Data {
        var payload = Data()
        payload.append(u32(0)) // creation time
        payload.append(u32(0)) // modification time
        payload.append(u32(UInt32(timescale)))
        payload.append(u32(UInt32(duration)))
        payload.append(u32(0x00010000)) // rate 1.0 (16.16)
        payload.append(u16(0x0100)) // volume 1.0 (8.8)
        payload.append(Data(repeating: 0, count: 10)) // reserved
        payload.append(identityMatrix())
        payload.append(Data(repeating: 0, count: 24)) // pre_defined
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
        payload.append(u32(0)) // creation
        payload.append(u32(0)) // modification
        payload.append(u32(UInt32(track.trackId)))
        payload.append(u32(0)) // reserved
        payload.append(u32(UInt32(track.durationTicks)))
        payload.append(Data(repeating: 0, count: 8)) // reserved
        payload.append(u16(0)) // layer
        payload.append(u16(0)) // alternate group
        payload.append(u16(track.isVideo ? 0 : 0x0100)) // volume
        payload.append(u16(0)) // reserved
        payload.append(identityMatrix())
        if let width = track.width, let height = track.height {
            payload.append(u32(UInt32(width) << 16)) // width 16.16
            payload.append(u32(UInt32(height) << 16))
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
        payload.append(u32(0)) // creation
        payload.append(u32(0)) // modification
        payload.append(u32(UInt32(track.timescale)))
        payload.append(u32(UInt32(track.durationTicks)))
        payload.append(u16(languageCode(track.language)))
        payload.append(u16(0)) // quality
        return fullBox("mdhd", version: 0, flags: 0, payload)
    }

    private static func hdlr(handlerType: String, name: String) -> Data {
        var payload = Data()
        payload.append(u32(0)) // pre_defined
        payload.append(contentsOf: handlerType.utf8)
        payload.append(Data(repeating: 0, count: 12)) // reserved
        payload.append(contentsOf: name.utf8)
        payload.append(u8(0))
        return fullBox("hdlr", version: 0, flags: 0, payload)
    }

    private static func minf(track: TransmuxTrack) -> Data {
        var payload = Data()
        if track.isVideo {
            var vmhd = Data()
            vmhd.append(u16(0)) // graphics mode
            vmhd.append(Data(repeating: 0, count: 6)) // opcolor
            payload.append(fullBox("vmhd", version: 0, flags: 1, vmhd))
        } else {
            var smhd = Data()
            smhd.append(u16(0)) // balance
            smhd.append(u16(0)) // reserved
            payload.append(fullBox("smhd", version: 0, flags: 0, smhd))
        }
        payload.append(dinf())
        payload.append(stbl(track: track))
        return box("minf", payload)
    }

    private static func dinf() -> Data {
        // dref = fullbox(version/flags + entry count) with the self-contained url entry inside.
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

    /// Empty sample-table boxes: fragmented movies keep sample data in fragments.
    /// stsz additionally carries sample_size + sample_count (not just an entry count).
    private static func emptyTable(_ type: String) -> Data {
        if type == "stsz" {
            return fullBox(type, version: 0, flags: 0, u32(0) + u32(0))
        }
        return fullBox(type, version: 0, flags: 0, u32(0))
    }

    private static func stsd(track: TransmuxTrack) -> Data {
        var payload = Data()
        payload.append(u32(1)) // entry count
        payload.append(sampleEntry(track: track))
        return fullBox("stsd", version: 0, flags: 0, payload)
    }

    private static func mvex(tracks: [TransmuxTrack]) -> Data {
        var payload = Data()
        for track in tracks {
            var trex = Data()
            trex.append(u32(UInt32(track.trackId)))
            trex.append(u32(1)) // default sample description index
            trex.append(u32(0)) // default sample duration
            trex.append(u32(0)) // default sample size
            trex.append(u32(0)) // default sample flags
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

    // MARK: - Sample entries

    private static func sampleEntry(track: TransmuxTrack) -> Data {
        switch track.codec {
        case .h264, .hevc:
            return videoSampleEntry(track: track)
        case .aac, .eac3, .ac3, .alac:
            return audioSampleEntry(track: track)
        case .unknown:
            return Data()
        }
    }

    private static func videoSampleEntry(track: TransmuxTrack) -> Data {
        var payload = Data()
        payload.append(Data(repeating: 0, count: 6)) // reserved
        payload.append(u16(1)) // data reference index
        payload.append(u16(0)) // pre_defined
        payload.append(u16(0)) // reserved
        payload.append(Data(repeating: 0, count: 12)) // pre_defined
        payload.append(u16(UInt16(track.width ?? 0)))
        payload.append(u16(UInt16(track.height ?? 0)))
        payload.append(u32(0x00480000)) // horizontal resolution
        payload.append(u32(0x00480000)) // vertical resolution
        payload.append(u32(0)) // reserved
        payload.append(u16(1)) // frame count
        payload.append(compressorname(""))
        payload.append(u16(0x0018)) // depth
        payload.append(u16(0xFFFF)) // pre_defined
        if let config = track.codecPrivate {
            payload.append(box(track.codec == .h264 ? "avcC" : "hvcC", config))
        }
        return box(track.codec == .h264 ? "avc1" : "hvc1", payload)
    }

    private static func audioSampleEntry(track: TransmuxTrack) -> Data {
        var payload = Data()
        payload.append(Data(repeating: 0, count: 6)) // reserved
        payload.append(u16(1)) // data reference index
        payload.append(u16(0)) // version
        payload.append(u16(0)) // revision level
        payload.append(u32(0)) // vendor
        payload.append(u16(UInt16(track.channels)))
        payload.append(u16(UInt16(track.bitDepth)))
        payload.append(u16(0)) // pre_defined (compression id)
        payload.append(u16(0)) // packet size
        payload.append(u32(UInt32(track.sampleRate) << 16)) // sample rate 16.16
        switch track.codec {
        case .aac:
            payload.append(esds(audioSpecificConfig: track.codecPrivate))
        case .eac3:
            if let config = track.audioConfig {
                payload.append(box("dec3", config))
            }
        case .ac3:
            if let config = track.audioConfig {
                payload.append(box("dac3", config))
            }
        case .alac:
            if let cookie = track.codecPrivate {
                payload.append(box("alac", Data(repeating: 0, count: 4) + cookie))
            }
        default:
            break
        }
        return box("mp4a", payload)
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
        guard let language, language.count == 3 else { return 0x55C4 } // und
        var value: UInt16 = 0
        for ch in language.utf8.prefix(3) {
            value = (value << 5) | UInt16(ch - 0x60)
        }
        return value
    }

    /// `esds` box for AAC: ES_Descriptor → DecoderConfig → AudioSpecificConfig.
    static func esds(audioSpecificConfig: Data?) -> Data {
        let asc = audioSpecificConfig ?? Data()
        let slConfig: [UInt8] = [0x02]
        var decSpecific = Data()
        decSpecific.append(0x05) // DecoderSpecificInfo tag
        decSpecific.append(descriptorLength(asc.count))
        decSpecific.append(asc)
        var decoderConfig = Data()
        decoderConfig.append(0x40) // objectTypeIndication: MPEG-4 Audio
        decoderConfig.append(0x15) // streamType: audio (0x05 << 2 | 1)
        decoderConfig.append(u24(0)) // buffer size DB
        decoderConfig.append(u32(0)) // max bitrate
        decoderConfig.append(u32(0)) // avg bitrate
        decoderConfig.append(decSpecific)
        var es = Data()
        es.append(u16(0)) // ES_ID
        es.append(u8(0)) // flags
        es.append(0x04) // DecoderConfig tag
        es.append(descriptorLength(decoderConfig.count))
        es.append(decoderConfig)
        es.append(0x06) // SLConfig tag
        es.append(descriptorLength(slConfig.count))
        es.append(contentsOf: slConfig)
        var payload = Data()
        payload.append(0x03) // ES_Descriptor tag
        payload.append(descriptorLength(es.count))
        payload.append(es)
        return fullBox("esds", version: 0, flags: 0, payload)
    }

    /// 7-bit-group descriptor length, big-endian with continuation bits.
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

    // MARK: - Box primitives

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
