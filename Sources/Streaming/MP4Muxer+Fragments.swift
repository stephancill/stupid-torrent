import Foundation

/// A fragment's samples for one track (already in decode order).
public struct TransmuxFragment: Sendable {
    public var trackId: Int
    public var samples: [TransmuxSample]
}

extension MP4Muxer {

    // MARK: - Fragments

    /// Builds one fragment: `moof` (mfhd + one traf per track) followed by `mdat`.
    /// `sequenceNumber` must increase monotonically across fragments. Fragment order in
    /// `fragments` defines mdat byte order and traf order.
    public static func fragment(sequenceNumber: Int, tracks: [TransmuxTrack], fragments: [TransmuxFragment]) -> Data {
        let usable = fragments.compactMap { fragment -> (track: TransmuxTrack, samples: [TransmuxSample])? in
            guard let track = tracks.first(where: { $0.trackId == fragment.trackId }),
                  !fragment.samples.isEmpty else { return nil }
            return (track, fragment.samples)
        }
        guard !usable.isEmpty else { return Data() }

        // First pass with a zero data offset to measure the exact moof box size; traf sizes
        // don't depend on the data offset, so the measured size is final.
        let probe = buildMoof(sequenceNumber: sequenceNumber, usable: usable, dataOffsets: [:])
        let moofBoxSize = probe.count

        // Data offsets are relative to the moof start (default-base-is-moof), pointing past
        // the moof box and the 8-byte mdat header.
        var running = 0
        var offsets: [Int: Int] = [:]
        for item in usable {
            offsets[item.track.trackId] = moofBoxSize + 8 + running
            running += item.samples.reduce(0) { $0 + $1.data.count }
        }

        let moof = buildMoof(sequenceNumber: sequenceNumber, usable: usable, dataOffsets: offsets)
        var mdat = Data()
        for item in usable {
            for sample in item.samples {
                mdat.append(sample.data)
            }
        }
        var data = Data()
        data.append(moof)
        data.append(box("mdat", mdat))
        return data
    }

    private static func buildMoof(
        sequenceNumber: Int,
        usable: [(track: TransmuxTrack, samples: [TransmuxSample])],
        dataOffsets: [Int: Int]
    ) -> Data {
        var payload = Data()
        payload.append(mfhd(sequenceNumber: sequenceNumber))
        for item in usable {
            var traf = Data()
            traf.append(tfhd(trackId: item.track.trackId))
            traf.append(tfdt(baseDecodeTime: item.samples.first!.decodeTimeTicks))
            traf.append(trun(samples: item.samples, dataOffset: dataOffsets[item.track.trackId] ?? 0))
            payload.append(box("traf", traf))
        }
        return box("moof", payload)
    }

    private static func mfhd(sequenceNumber: Int) -> Data {
        fullBox("mfhd", version: 0, flags: 0, u32(UInt32(sequenceNumber)))
    }

    private static func tfhd(trackId: Int) -> Data {
        // default-base-is-moof: the trun data offset is relative to the moof start.
        let flags: UInt32 = 0x20000
        var payload = Data()
        payload.append(u32(UInt32(trackId)))
        return fullBox("tfhd", version: 0, flags: flags, payload)
    }

    private static func tfdt(baseDecodeTime: Int64) -> Data {
        fullBox("tfdt", version: 1, flags: 0, u64(UInt64(baseDecodeTime)))
    }

    private static func trun(samples: [TransmuxSample], dataOffset: Int) -> Data {
        // data_offset(0x1) + sample_duration(0x100) + sample_size(0x200)
        // + sample_flags(0x400) + sample_composition_time_offsets(0x800).
        // Composition offsets are always present so the trun size is a pure function of the
        // sample count (deterministic fragment sizing for the sidx); zero offsets are valid.
        let flags: UInt32 = 0x1 | 0x100 | 0x200 | 0x400 | 0x800
        var payload = Data()
        payload.append(u32(UInt32(samples.count)))
        payload.append(u32(UInt32(dataOffset)))
        for sample in samples {
            payload.append(u32(UInt32(sample.durationTicks)))
            payload.append(u32(UInt32(sample.data.count)))
            payload.append(u32(sampleFlags(sample)))
            payload.append(u32(UInt32(bitPattern: Int32(sample.compositionOffsetTicks))))
        }
        return fullBox("trun", version: 1, flags: flags, payload)
    }

    /// Sample flags: sync samples have `sample_depends_on` = 2 and no redundant coding;
    /// delta samples have `sample_depends_on` = 1, `sample_is_non_sync_sample` = 1.
    static func sampleFlags(_ sample: TransmuxSample) -> UInt32 {
        sample.isKeyframe ? 0x02000000 : 0x01010000
    }

    // MARK: - Segment index

    /// `sidx` box (version 1) listing the media subsegments. `references` are (size, durationTicks)
    /// pairs in file order; `timescale` matches the movie timescale. Emitted in the init segment
    /// when the fragment layout is known up front (whole file verified).
    public static func sidx(timescale: Int, references: [(size: Int, durationTicks: Int64)]) -> Data {
        var payload = Data()
        payload.append(u32(1)) // reference_ID
        payload.append(u32(UInt32(timescale)))
        payload.append(u64(0)) // earliest presentation time
        payload.append(u64(0)) // first_offset (fragments follow this box)
        payload.append(u16(0)) // reserved
        payload.append(u16(UInt16(references.count)))
        for (size, duration) in references {
            payload.append(u32(UInt32(size) & 0x7FFFFFFF)) // reference_type 0 + size
            payload.append(u32(UInt32(duration))) // subsegment duration
            payload.append(u32(0)) // starts_with_SAP + SAP_type + SAP_delta_time
        }
        return fullBox("sidx", version: 1, flags: 0, payload)
    }
}

// MARK: - E-AC-3 / AC-3 config (dec3 / dac3)

extension MP4Muxer {

    /// Parses an E-AC-3 syncframe header (as found in `A_EAC3` block payloads / CodecPrivate)
    /// and returns the `dec3` box payload. Returns nil if the data isn't a valid syncframe.
    public static func eac3Config(fromSyncframe data: Data) -> Data? {
        guard let fields = parseEAC3Syncframe(data) else { return nil }
        var bits = BitWriter()
        bits.write(fields.dataRate, 13)
        bits.write(0, 3) // num_ind_sub - 1 (single independent substream)
        bits.write(fields.fscod, 2)
        bits.write(fields.bsid, 5)
        bits.write(fields.bsmod, 5)
        bits.write(fields.acmod, 3)
        bits.write(fields.lfeon, 1)
        bits.write(0, 3) // reserved
        bits.write(0, 4) // num_dep_sub
        bits.write(0, 1) // reserved (no dependent substreams → no chan_loc)
        return bits.flush()
    }

    /// Parses an AC-3 syncframe header and returns the `dac3` box payload.
    public static func ac3Config(fromSyncframe data: Data) -> Data? {
        guard let fields = parseAC3Syncframe(data) else { return nil }
        var bits = BitWriter()
        bits.write(fields.fscod, 2)
        bits.write(fields.bsid, 5)
        bits.write(fields.bsmod, 3)
        bits.write(fields.acmod, 3)
        bits.write(fields.lfeon, 1)
        bits.write(fields.bitRateCode, 5)
        bits.write(0, 5) // reserved
        return bits.flush()
    }

    private struct EAC3Syncframe {
        var fscod: Int
        var bsid: Int
        var bsmod: Int
        var acmod: Int
        var lfeon: Int
        var dataRate: Int
    }

    private static func parseEAC3Syncframe(_ data: Data) -> EAC3Syncframe? {
        guard data.count >= 6 else { return nil }
        var reader = BitReader(data)
        guard reader.read(16) == 0x0B77 else { return nil }
        _ = reader.read(2) // strmtyp
        _ = reader.read(3) // substreamid
        let frmsiz = reader.read(11)
        let fscod = reader.read(2)
        var sampleRate: Double
        if fscod == 3 {
            let fscod2 = reader.read(2)
            sampleRate = [24000, 22050, 16000][fscod2]
        } else {
            sampleRate = [48000, 44100, 32000][fscod]
        }
        let acmod = reader.read(3)
        let lfeon = reader.read(1)
        let bsid = reader.read(5)
        // Data rate is derived from the frame size: each syncframe covers one 32 ms audio block
        // at 48 kHz (or 26.7 ms at 24 kHz), so rate = frameBytes * 8 * (blocksPerSecond).
        let frameBytes = 2 * (frmsiz + 1)
        let dataRate = Int((Double(frameBytes) * 8 * sampleRate / 1536.0) / 1000.0)
        return EAC3Syncframe(fscod: fscod, bsid: bsid, bsmod: 0, acmod: acmod, lfeon: lfeon, dataRate: dataRate)
    }

    private struct AC3Syncframe {
        var fscod: Int
        var bsid: Int
        var bsmod: Int
        var acmod: Int
        var lfeon: Int
        var bitRateCode: Int
    }

    private static func parseAC3Syncframe(_ data: Data) -> AC3Syncframe? {
        guard data.count >= 6 else { return nil }
        var reader = BitReader(data)
        guard reader.read(16) == 0x0B77 else { return nil }
        _ = reader.read(16) // crc1
        let fscod = reader.read(2)
        let frmsizecod = reader.read(6)
        let bsid = reader.read(5)
        let bsmod = reader.read(3)
        let acmod = reader.read(3)
        let lfeon = reader.read(1)
        _ = frmsizecod
        return AC3Syncframe(fscod: fscod, bsid: bsid, bsmod: bsmod, acmod: acmod, lfeon: lfeon, bitRateCode: frmsizecod)
    }
}

/// MSB-first bit writer (used for dec3/dac3).
struct BitWriter {
    private var data = Data()
    private var current: UInt8 = 0
    private var nbits = 0

    mutating func write(_ value: Int, _ count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            current = (current << 1) | UInt8((value >> shift) & 1)
            nbits += 1
            if nbits == 8 {
                data.append(current)
                current = 0
                nbits = 0
            }
        }
    }

    func flush() -> Data {
        data
    }
}

/// MSB-first bit reader over a Data buffer.
struct BitReader {
    private let data: Data
    private var bitIndex = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byteIndex = bitIndex / 8
            let bitInByte = 7 - (bitIndex % 8)
            guard byteIndex < data.count else { return value }
            value = (value << 1) | Int((data[data.startIndex + byteIndex] >> bitInByte) & 1)
            bitIndex += 1
        }
        return value
    }
}
