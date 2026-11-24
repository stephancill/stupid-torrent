import Foundation

enum EBMLID: UInt64 {
    case ebml = 0x1A45DFA3
    case segment = 0x18538067
    case seekHead = 0x114D9B74
    case seek = 0x4DBB
    case seekID = 0x53AB
    case seekPosition = 0x53AC

    case info = 0x1549A966
    case timestampScale = 0x2AD7B1
    case duration = 0x4489

    case tracks = 0x1654AE6B
    case trackEntry = 0xAE
    case trackNumber = 0xD7
    case trackType = 0x83
    case flagEnabled = 0xB9
    case flagDefault = 0x88
    case language = 0x22B59C
    case codecID = 0x86
    case codecPrivate = 0x63A2
    case defaultDuration = 0x23E383

    case video = 0xE0
    case pixelWidth = 0xB0
    case pixelHeight = 0xBA

    case audio = 0xE1
    case samplingFrequency = 0xB5
    case channels = 0x9F
    case bitDepth = 0x6264

    case cluster = 0x1F43B675
    case clusterTimestamp = 0xE7
    case simpleBlock = 0xA3
    case blockGroup = 0xA0
    case block = 0xA1
    case blockDuration = 0x9B
    case referenceBlock = 0xFB

    case cues = 0x1C53BB6B
    case cuePoint = 0xBB
    case cueTime = 0xB3
    case cueTrackPositions = 0xB7
    case cueTrack = 0xF7
    case cueClusterPosition = 0xF1

    case chapters = 0x1043A770
    case tags = 0x1254C367
    case attachments = 0x1941A469

    static func isTopLevel(_ id: UInt64) -> Bool {
        switch EBMLID(rawValue: id) {
        case .segment, .info, .tracks, .cluster, .cues, .seekHead, .chapters, .tags, .attachments:
            true
        default:
            false
        }
    }
}

struct EBMLHeader {
    let id: UInt64
    let size: UInt64?
    let length: Int
}

enum EBML {
    static func readVarInt(in data: Data, offset: Int) -> (value: UInt64, length: Int)? {
        guard offset >= 0, offset < data.count else { return nil }
        let first = data[data.startIndex + offset]
        guard first != 0 else { return nil }
        let width = first.leadingZeroBitCount + 1
        guard offset + width <= data.count else { return nil }
        var value = UInt64(first & (0xFF >> width))
        for index in 1..<width {
            value = (value << 8) | UInt64(data[data.startIndex + offset + index])
        }
        return (value, width)
    }

    static func readHeader(in data: Data, offset: Int) -> EBMLHeader? {
        guard let idInfo = readVarInt(in: data, offset: offset), idInfo.length <= 4,
              let sizeInfo = readVarInt(in: data, offset: offset + idInfo.length) else { return nil }
        var id: UInt64 = 0
        for index in 0..<idInfo.length {
            id = (id << 8) | UInt64(data[data.startIndex + offset + index])
        }
        let undefinedMask: UInt64 = (1 << (7 * UInt64(sizeInfo.length))) - 1
        return EBMLHeader(
            id: id,
            size: sizeInfo.value == undefinedMask ? nil : sizeInfo.value,
            length: idInfo.length + sizeInfo.length
        )
    }

    static func forEachChild(
        in data: Data,
        range: Range<Int>,
        _ body: (_ header: EBMLHeader, _ value: Range<Int>) throws -> Void
    ) throws {
        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            throw MatroskaError.truncated("element")
        }
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard let header = readHeader(in: data, offset: cursor) else {
                throw MatroskaError.corrupt("child header at \(cursor)")
            }
            guard let size = header.size else {
                throw MatroskaError.undefinedSize("child 0x\(String(header.id, radix: 16))")
            }
            let valueStart = cursor + header.length
            guard valueStart <= range.upperBound, size <= UInt64(range.upperBound - valueStart) else {
                throw MatroskaError.corrupt("child 0x\(String(header.id, radix: 16)) overruns its parent")
            }
            let value = valueStart..<valueStart + Int(size)
            try body(header, value)
            cursor = value.upperBound
        }
    }

    static func readUInt(in data: Data, range: Range<Int>) throws -> UInt64 {
        guard range.count <= 8, range.lowerBound >= 0, range.upperBound <= data.count else {
            throw MatroskaError.corrupt("unsigned integer of \(range.count) bytes")
        }
        var value: UInt64 = 0
        for index in range {
            value = (value << 8) | UInt64(data[data.startIndex + index])
        }
        return value
    }

    static func readInt(in data: Data, range: Range<Int>) throws -> Int64 {
        let unsigned = try readUInt(in: data, range: range)
        guard !range.isEmpty, range.count < 8 else { return Int64(bitPattern: unsigned) }
        let bits = UInt64(range.count * 8)
        let signBit = UInt64(1) << (bits - 1)
        return unsigned & signBit == 0 ? Int64(unsigned) : Int64(unsigned) - Int64(1 << bits)
    }

    static func readFloat(in data: Data, range: Range<Int>) throws -> Double {
        switch range.count {
        case 4: Double(Float(bitPattern: UInt32(try readUInt(in: data, range: range))))
        case 8: Double(bitPattern: try readUInt(in: data, range: range))
        default: throw MatroskaError.corrupt("float of \(range.count) bytes")
        }
    }

    static func readString(in data: Data, range: Range<Int>) throws -> String {
        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            throw MatroskaError.corrupt("string")
        }
        var bytes = data[data.startIndex + range.lowerBound..<data.startIndex + range.upperBound]
        while bytes.last == 0 { bytes = bytes.dropLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
