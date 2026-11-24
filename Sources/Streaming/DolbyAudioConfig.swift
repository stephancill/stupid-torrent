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
        writer.write(0, bits: 4)
        writer.write(0, bits: 1)
        return writer.bytes
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
