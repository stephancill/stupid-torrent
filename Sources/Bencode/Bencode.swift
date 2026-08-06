import Foundation

public enum BencodeError: Error, Equatable, Sendable {
    case invalidToken(UInt8)
    case truncated
    case invalidInteger(String)
    case invalidLength(String)
    case trailingData
    case depthExceeded
    case notDictionary
    case keyNotFound(String)
    case notAString
}

public enum BValue: Sendable, Equatable {
    case int(Int)
    case string(Data)
    case list([BValue])
    case dictionary([String: BValue])

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var stringValue: Data? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var stringValueUTF8: String? {
        guard let data = stringValue else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public var listValue: [BValue]? {
        if case .list(let value) = self { return value }
        return nil
    }

    public var dictionaryValue: [String: BValue]? {
        if case .dictionary(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> BValue? {
        guard case .dictionary(let dict) = self else { return nil }
        return dict[key]
    }
}

public enum Bencode {
    public static func decode(_ data: Data) throws -> BValue {
        var parser = Parser(bytes: [UInt8](data))
        return try parser.parse()
    }

    /// Decodes a single value from the start of `data`, returning the value and the number of
    /// bytes consumed. Does not require the whole input to be consumed (useful for framing
    /// protocols like ut_metadata where a dict is followed by a raw byte chunk).
    public static func decodeFirst(_ data: Data) throws -> (value: BValue, consumed: Int) {
        var parser = Parser(bytes: [UInt8](data))
        let value = try parser.parseValue(depth: 0)
        return (value, parser.index)
    }

    public static func encode(_ value: BValue) -> Data {
        switch value {
        case .int(let intValue):
            return Data("i\(intValue)e".utf8)
        case .string(let bytes):
            var out = Data()
            out.append(Data("\(bytes.count):".utf8))
            out.append(bytes)
            return out
        case .list(let elements):
            var out = Data("l".utf8)
            for element in elements {
                out.append(encode(element))
            }
            out.append(Data("e".utf8))
            return out
        case .dictionary(let dictionary):
            var out = Data("d".utf8)
            for key in dictionary.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                let keyBytes = Data(key.utf8)
                out.append(Data("\(keyBytes.count):".utf8))
                out.append(keyBytes)
                out.append(encode(dictionary[key]!))
            }
            out.append(Data("e".utf8))
            return out
        }
    }

    /// Returns the raw bytes of the value for `key` inside a top-level dictionary,
    /// preserving the exact byte sequence (needed to compute an info-hash).
    public static func rawValue(forKey key: String, in data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var index = 0
        guard index < bytes.count, bytes[index] == UInt8(ascii: "d") else {
            throw BencodeError.notDictionary
        }
        index += 1
        let keyData = Data(key.utf8)
        while index < bytes.count {
            let keyBytes = try readLengthPrefixed(bytes: bytes, index: &index)
            let valueStart = index
            try skipValue(bytes: bytes, index: &index)
            if keyBytes == keyData {
                return Data(bytes[valueStart..<index])
            }
        }
        throw BencodeError.keyNotFound(key)
    }
}

private func readLengthPrefixed(bytes: [UInt8], index: inout Int) throws -> Data {
    var lengthBytes: [UInt8] = []
    while index < bytes.count, bytes[index] != UInt8(ascii: ":") {
        lengthBytes.append(bytes[index])
        index += 1
    }
    guard index < bytes.count else { throw BencodeError.truncated }
    index += 1
    let token = String(decoding: lengthBytes, as: UTF8.self)
    guard isValidNumberToken(token), let length = Int(token) else {
        throw BencodeError.invalidLength(token)
    }
    guard index + length <= bytes.count else { throw BencodeError.truncated }
    let result = Data(bytes[index..<index + length])
    index += length
    return result
}

private func skipValue(bytes: [UInt8], index: inout Int) throws {
    guard index < bytes.count else { throw BencodeError.truncated }
    let byte = bytes[index]
    switch byte {
    case UInt8(ascii: "i"):
        index += 1
        while index < bytes.count, bytes[index] != UInt8(ascii: "e") { index += 1 }
        guard index < bytes.count else { throw BencodeError.truncated }
        index += 1
    case UInt8(ascii: "l"):
        index += 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "e") {
                index += 1
                return
            }
            try skipValue(bytes: bytes, index: &index)
        }
        throw BencodeError.truncated
    case UInt8(ascii: "d"):
        index += 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "e") {
                index += 1
                return
            }
            _ = try readLengthPrefixed(bytes: bytes, index: &index)
            try skipValue(bytes: bytes, index: &index)
        }
        throw BencodeError.truncated
    case UInt8(ascii: "0")...UInt8(ascii: "9"):
        _ = try readLengthPrefixed(bytes: bytes, index: &index)
    default:
        throw BencodeError.invalidToken(byte)
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index: Int
    let maxDepth = 64

    init(bytes: [UInt8]) {
        self.bytes = bytes
        self.index = 0
    }

    mutating func parse() throws -> BValue {
        let value = try parseValue(depth: 0)
        guard index == bytes.count else { throw BencodeError.trailingData }
        return value
    }

    mutating func parseValue(depth: Int) throws -> BValue {
        guard depth <= maxDepth else { throw BencodeError.depthExceeded }
        guard index < bytes.count else { throw BencodeError.truncated }
        let byte = bytes[index]
        switch byte {
        case UInt8(ascii: "i"):
            return .int(try parseInteger())
        case UInt8(ascii: "l"):
            return .list(try parseList(depth: depth))
        case UInt8(ascii: "d"):
            return .dictionary(try parseDictionary(depth: depth))
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .string(try parseString())
        default:
            throw BencodeError.invalidToken(byte)
        }
    }

    mutating func parseInteger() throws -> Int {
        index += 1
        let start = index
        while index < bytes.count, bytes[index] != UInt8(ascii: "e") { index += 1 }
        guard index < bytes.count else { throw BencodeError.truncated }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        index += 1
        guard isValidIntegerToken(token), let value = Int(token) else {
            throw BencodeError.invalidInteger(token)
        }
        return value
    }

    mutating func parseString() throws -> Data {
        var lengthBytes: [UInt8] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: ":") {
            lengthBytes.append(bytes[index])
            index += 1
        }
        guard index < bytes.count else { throw BencodeError.truncated }
        index += 1
        let token = String(decoding: lengthBytes, as: UTF8.self)
        guard isValidNumberToken(token), let length = Int(token) else {
            throw BencodeError.invalidLength(token)
        }
        guard index + length <= bytes.count else { throw BencodeError.truncated }
        let result = Data(bytes[index..<index + length])
        index += length
        return result
    }

    mutating func parseList(depth: Int) throws -> [BValue] {
        index += 1
        var values: [BValue] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: "e") {
            values.append(try parseValue(depth: depth + 1))
        }
        guard index < bytes.count else { throw BencodeError.truncated }
        index += 1
        return values
    }

    mutating func parseDictionary(depth: Int) throws -> [String: BValue] {
        index += 1
        var values: [String: BValue] = [:]
        while index < bytes.count, bytes[index] != UInt8(ascii: "e") {
            let keyData = try parseString()
            let key = decodeKey(keyData)
            values[key] = try parseValue(depth: depth + 1)
        }
        guard index < bytes.count else { throw BencodeError.truncated }
        index += 1
        return values
    }
}

private func decodeKey(_ data: Data) -> String {
    if let string = String(data: data, encoding: .utf8) {
        return string
    }
    return String(data: data, encoding: .isoLatin1) ?? ""
}

private func isValidNumberToken(_ token: String) -> Bool {
    !token.isEmpty && token.allSatisfy { $0.isASCII && $0.isNumber }
}

private func isValidIntegerToken(_ token: String) -> Bool {
    if token.isEmpty || token == "-0" { return false }
    if token == "-" { return false }
    if token.first == "-" {
        let digits = token.dropFirst()
        if digits.count > 1 && digits.first == "0" { return false }
        return digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
    if token.count > 1 && token.first == "0" { return false }
    return token.allSatisfy { $0.isASCII && $0.isNumber }
}
