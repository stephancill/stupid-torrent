import Foundation

enum DolbyAudioConfig {
    static func dac3(syncframe: Data) -> Data? {
        var reader = BitReader(data: syncframe)
        guard syncframe.count >= 8, reader.read(bits: 16) == 0x0B77 else { return nil }
        reader.skip(bits: 16)
        let fscod = reader.read(bits: 2)
        let frmsizecod = reader.read(bits: 6)
        let bsid = reader.read(bits: 5)
        let bsmod = reader.read(bits: 3)
        let acmod = reader.read(bits: 3)
        guard fscod != 3, frmsizecod < 38, bsid <= 10 else { return nil }
        if acmod & 0x1 != 0, acmod != 0x1 { reader.skip(bits: 2) }
        if acmod & 0x4 != 0 { reader.skip(bits: 2) }
        if acmod == 0x2 { reader.skip(bits: 2) }
        let lfeon = reader.read(bits: 1)

        var writer = BitWriter()
        writer.write(fscod, bits: 2)
        writer.write(bsid, bits: 5)
        writer.write(bsmod, bits: 3)
        writer.write(acmod, bits: 3)
        writer.write(lfeon, bits: 1)
        writer.write(frmsizecod >> 1, bits: 5)
        writer.write(0, bits: 5)
        return writer.bytes
    }

    static func dec3(syncframe: Data) -> Data? {
        var reader = BitReader(data: syncframe)
        guard syncframe.count >= 6, reader.read(bits: 16) == 0x0B77 else { return nil }
        let strmtyp = reader.read(bits: 2)
        reader.skip(bits: 3)
        let frameBytes = 2 * (reader.read(bits: 11) + 1)
        let fscod = reader.read(bits: 2)
        let sampleRate: Int
        let blocks: Int
        if fscod == 3 {
            let fscod2 = reader.read(bits: 2)
            guard fscod2 != 3 else { return nil }
            sampleRate = [24000, 22050, 16000][fscod2]
            blocks = 6
        } else {
            sampleRate = [48000, 44100, 32000][fscod]
            blocks = [1, 2, 3, 6][reader.read(bits: 2)]
        }
        let acmod = reader.read(bits: 3)
        let lfeon = reader.read(bits: 1)
        let bsid = reader.read(bits: 5)
        guard strmtyp != 1, (11...16).contains(bsid) else { return nil }
        let dataRate = frameBytes * 8 * sampleRate / (blocks * 256) / 1000

        var writer = BitWriter()
        writer.write(dataRate, bits: 13)
        writer.write(0, bits: 3)
        writer.write(fscod, bits: 2)
        writer.write(bsid, bits: 5)
        writer.write(0, bits: 1)
        writer.write(0, bits: 1)
        writer.write(0, bits: 3)
        writer.write(acmod, bits: 3)
        writer.write(lfeon, bits: 1)
        writer.write(0, bits: 3)
        let dependents = dependentSubstreams(in: syncframe, after: frameBytes)
        writer.write(dependents.count, bits: 4)
        if dependents.count == 0 {
            writer.write(0, bits: 1)
        } else {
            writer.write(dependents.channelLocations, bits: 9)
        }
        return writer.bytes
    }

    private static func dependentSubstreams(in frame: Data, after offset: Int) -> (count: Int, channelLocations: Int) {
        var count = 0
        var channelLocations = 0
        var cursor = offset
        while count < 15, cursor + 6 <= frame.count {
            var reader = BitReader(data: frame.dropFirst(cursor))
            guard reader.read(bits: 16) == 0x0B77, reader.read(bits: 2) == 1 else { break }
            reader.skip(bits: 3)
            let frameBytes = 2 * (reader.read(bits: 11) + 1)
            reader.skip(bits: 4)
            let acmod = reader.read(bits: 3)
            reader.skip(bits: 6)
            for _ in 0..<(acmod == 0 ? 2 : 1) {
                reader.skip(bits: 5)
                if reader.read(bits: 1) == 1 { reader.skip(bits: 8) }
            }
            if reader.read(bits: 1) == 1 {
                let chanmap = reader.read(bits: 16)
                for bit in 0..<8 where (chanmap >> (10 - bit)) & 1 == 1 {
                    channelLocations |= 1 << bit
                }
                if (chanmap >> 1) & 1 == 1 { channelLocations |= 1 << 8 }
            } else {
                channelLocations |= acmod
            }
            count += 1
            cursor += frameBytes
        }
        return (count, channelLocations)
    }
}

struct BitWriter {
    private var data = Data()
    private var current: UInt8 = 0
    private var count = 0

    mutating func write(_ value: Int, bits: Int) {
        for shift in stride(from: bits - 1, through: 0, by: -1) {
            current = (current << 1) | UInt8((value >> shift) & 1)
            count += 1
            if count == 8 {
                data.append(current)
                current = 0
                count = 0
            }
        }
    }

    var bytes: Data {
        guard count > 0 else { return data }
        return data + [current << (8 - count)]
    }
}

struct BitReader {
    let data: Data
    private var position = 0

    init(data: Data) {
        self.data = data
    }

    mutating func read(bits: Int) -> Int {
        var value = 0
        for _ in 0..<bits {
            let byteIndex = position / 8
            let bit = byteIndex < data.count ? (data[data.startIndex + byteIndex] >> (7 - position % 8)) & 1 : 0
            value = (value << 1) | Int(bit)
            position += 1
        }
        return value
    }

    mutating func skip(bits: Int) {
        position += bits
    }
}
