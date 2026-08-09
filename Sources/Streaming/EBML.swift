import Foundation

/// Matroska EBML element IDs (subset used by the transmuxer).
enum EBMLID: UInt64 {
    case ebml = 0x1A45DFA3
    case ebmlVersion = 0x4286
    case ebmlReadVersion = 0x42F7
    case ebmlMaxIDLength = 0x42F2
    case ebmlMaxSizeLength = 0x42F3
    case docType = 0x4282
    case docTypeVersion = 0x4287
    case docTypeReadVersion = 0x4285

    case void = 0xEC
    case crc32 = 0xBF

    case segment = 0x18538067
    case seekHead = 0x114D9B74
    case seek = 0x4DBB
    case seekID = 0x53AB
    case seekPosition = 0x53AC

    case info = 0x1549A966
    case timestampScale = 0x2AD7B1
    case duration = 0x4489
    case muxingApp = 0x4D80
    case writingApp = 0x5741

    case tracks = 0x1654AE6B
    case trackEntry = 0xAE
    case trackNumber = 0xD7
    case trackUID = 0x73C5
    case trackType = 0x83
    case flagEnabled = 0xB9
    case flagDefault = 0x88
    case flagForced = 0x55AA
    case flagLacing = 0x9C
    case name = 0x536E
    case language = 0x22B59C
    case codecID = 0x86
    case codecPrivate = 0x63A2
    case codecDelay = 0x56AA
    case seekPreRoll = 0x56BB
    case defaultDuration = 0x23E383

    case video = 0xE0
    case pixelWidth = 0xB0
    case pixelHeight = 0xBA
    case displayWidth = 0x54B0
    case displayHeight = 0x54BA
    case displayUnit = 0x54B2
    case colour = 0x55B0

    case audio = 0xE1
    case samplingFrequency = 0xB5
    case outputSamplingFrequency = 0x78B5
    case channels = 0x9F
    case bitDepth = 0x6264

    case cluster = 0x1F43B675
    case clusterTimestamp = 0xE7
    case simpleBlock = 0xA3
    case blockGroup = 0xA0
    case block = 0xA1
    case blockAdditions = 0x75A1
    case blockMore = 0xA6
    case blockAdditional = 0xA5
    case blockAddID = 0xEE
    case blockDuration = 0x9B
    case referenceBlock = 0xFB
    case discardPadding = 0x75A2

    case cues = 0x1C53BB6B
    case cuePoint = 0xBB
    case cueTime = 0xB3
    case cueTrackPositions = 0xB7
    case cueTrack = 0xF7
    case cueClusterPosition = 0xF1

    case chapters = 0x1043A770
    case tags = 0x1254C367
    case attachments = 0x1941A469
}

/// An EBML element header: its ID and size. `size == nil` means the size is undefined
/// (the element extends to the end of its parent).
struct EBMLHeader {
    let id: UInt64
    let size: UInt64?
    let idLength: Int
    let sizeLength: Int
}

/// Raw EBML primitives over `Data`. All functions are pure and offset-based so parsing can
/// operate on bounded slices (a fetched head region, a single cluster, ...) without copies.
enum EBML {
    /// Reads a variable-length integer at `offset`, returning its value and total byte length.
    /// Returns nil if the data is truncated or the VINT is invalid (all-zero first byte).
    static func readVarInt(_ data: Data, offset: Int) -> (value: UInt64, length: Int)? {
        guard offset < data.count else { return nil }
        let first = data[data.startIndex + offset]
        guard first != 0 else { return nil }

        var width = 1
        var mask: UInt8 = 0x80
        while first & mask == 0 {
            width += 1
            mask >>= 1
            if width > 8 { return nil }
        }
        guard offset + width <= data.count else { return nil }

        var value = UInt64(first & (mask - 1))
        for i in 1..<width {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return (value, width)
    }

    /// Reads an element header (ID + size). `size == nil` indicates an undefined size
    /// (reserved all-ones marker). Returns nil on truncation or invalid data.
    static func readHeader(_ data: Data, offset: Int) -> EBMLHeader? {
        guard let idInfo = readVarInt(data, offset: offset) else { return nil }
        // Element IDs carry the VINT marker bit as part of the value (unlike sizes).
        let id = readUInt(data, offset: offset, length: idInfo.length)
        let idPos = offset + idInfo.length
        guard let sizeInfo = readVarInt(data, offset: idPos) else { return nil }

        // A size field whose value is all-ones of its width means undefined size.
        let undefinedMask: UInt64
        if sizeInfo.length >= 8 {
            undefinedMask = UInt64.max
        } else {
            undefinedMask = (1 << (7 * UInt64(sizeInfo.length))) - 1
        }
        let size: UInt64? = sizeInfo.value == undefinedMask ? nil : sizeInfo.value
        return EBMLHeader(id: id, size: size, idLength: idInfo.length, sizeLength: sizeInfo.length)
    }

    /// Total byte length of an element's header (ID + size fields) given its header info.
    static func headerLength(_ header: EBMLHeader) -> Int {
        header.idLength + header.sizeLength
    }

    /// Reads an unsigned integer of `length` bytes (big-endian).
    static func readUInt(_ data: Data, offset: Int, length: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<length {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return value
    }

    /// Reads a signed integer of `length` bytes (big-endian, two's complement).
    static func readInt(_ data: Data, offset: Int, length: Int) -> Int64 {
        let unsigned = readUInt(data, offset: offset, length: length)
        let signBit = UInt64(1) << (UInt64(length) * 8 - 1)
        if unsigned & signBit != 0 {
            return Int64(bitPattern: unsigned &- (1 << (UInt64(length) * 8)))
        }
        return Int64(bitPattern: unsigned)
    }

    /// Reads an IEEE-754 float of `length` bytes (4 or 8, big-endian).
    static func readFloat(_ data: Data, offset: Int, length: Int) -> Double? {
        guard offset + length <= data.count else { return nil }
        if length == 4 {
            let value = readUInt(data, offset: offset, length: 4)
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: value)))
        }
        if length == 8 {
            let value = readUInt(data, offset: offset, length: 8)
            return Double(bitPattern: value)
        }
        return nil
    }

    /// Reads a NUL-trimmed UTF-8 string of `length` bytes.
    static func readString(_ data: Data, offset: Int, length: Int) -> String? {
        guard offset + length <= data.count else { return nil }
        var end = offset + length
        while end > offset, data[data.startIndex + end - 1] == 0 {
            end -= 1
        }
        return String(data: data.subdata(in: offset..<end), encoding: .utf8)
    }
}

/// Cursor-based reader over an in-memory slice, used to parse a bounded element's children.
struct EBMLReader {
    let data: Data
    let baseOffset: Int
    private(set) var position: Int

    init(data: Data, baseOffset: Int = 0) {
        self.data = data
        self.baseOffset = baseOffset
        self.position = baseOffset
    }

    /// Parses the next element header without consuming it. Returns nil at end of data.
    func peekHeader() -> EBMLHeader? {
        EBML.readHeader(data, offset: position)
    }

    /// Advances past the current element. Requires the element size to be known.
    mutating func skip() throws {
        guard let header = peekHeader() else { throw MatroskaError.truncated("element") }
        guard let size = header.size else { throw MatroskaError.undefinedSize("element") }
        position += EBML.headerLength(header) + Int(size)
    }

    var isAtEnd: Bool { position >= data.count }
}
