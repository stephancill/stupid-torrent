import Foundation

struct TransmuxFragment: Sendable {
    var trackId: Int
    var samples: [TransmuxSample]
}

extension MP4Muxer {
    static func fragment(sequenceNumber: Int, tracks: [TransmuxTrack], fragments: [TransmuxFragment]) -> Data {
        let usable = fragments.filter { fragment in
            !fragment.samples.isEmpty && tracks.contains { $0.trackId == fragment.trackId }
        }
        guard !usable.isEmpty else { return Data() }

        let moofSize = moof(sequenceNumber: sequenceNumber, fragments: usable, dataOffsets: [:]).count
        var running = 0
        var dataOffsets: [Int: Int] = [:]
        for fragment in usable {
            dataOffsets[fragment.trackId] = moofSize + 8 + running
            running += fragment.samples.reduce(0) { $0 + $1.data.count }
        }

        var mdat = Data(capacity: running)
        for fragment in usable {
            for sample in fragment.samples {
                mdat.append(sample.data)
            }
        }
        var data = moof(sequenceNumber: sequenceNumber, fragments: usable, dataOffsets: dataOffsets)
        data.append(box("mdat", mdat))
        return data
    }

    private static func moof(sequenceNumber: Int, fragments: [TransmuxFragment], dataOffsets: [Int: Int]) -> Data {
        var payload = fullBox("mfhd", version: 0, flags: 0, u32(UInt32(clamping: sequenceNumber)))
        for fragment in fragments {
            var traf = fullBox("tfhd", version: 0, flags: 0x20000, u32(UInt32(clamping: fragment.trackId)))
            traf.append(fullBox(
                "tfdt",
                version: 1,
                flags: 0,
                u64(UInt64(clamping: fragment.samples.first?.decodeTimeTicks ?? 0))
            ))
            traf.append(trun(samples: fragment.samples, dataOffset: dataOffsets[fragment.trackId] ?? 0))
            payload.append(box("traf", traf))
        }
        return box("moof", payload)
    }

    private static func trun(samples: [TransmuxSample], dataOffset: Int) -> Data {
        var payload = Data(capacity: 8 + 16 * samples.count)
        payload.append(u32(UInt32(clamping: samples.count)))
        payload.append(u32(UInt32(clamping: dataOffset)))
        for sample in samples {
            payload.append(u32(UInt32(clamping: sample.durationTicks)))
            payload.append(u32(UInt32(clamping: sample.data.count)))
            payload.append(u32(sample.isKeyframe ? 0x0200_0000 : 0x0101_0000))
            payload.append(u32(UInt32(bitPattern: Int32(clamping: sample.compositionOffsetTicks))))
        }
        return fullBox("trun", version: 1, flags: 0x1 | 0x100 | 0x200 | 0x400 | 0x800, payload)
    }
}
