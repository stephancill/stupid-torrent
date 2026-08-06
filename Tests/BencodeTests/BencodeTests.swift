import Testing
import Foundation
import Bencode

@Suite struct BencodeTests {
    @Test func decodeIntegers() throws {
        #expect(try Bencode.decode(Data("i0e".utf8)) == .int(0))
        #expect(try Bencode.decode(Data("i42e".utf8)) == .int(42))
        #expect(try Bencode.decode(Data("i-42e".utf8)) == .int(-42))
        #expect(try Bencode.decode(Data("i9223372036854775807e".utf8)) == .int(Int.max))
    }

    @Test func decodeStrings() throws {
        #expect(try Bencode.decode(Data("0:".utf8)) == .string(Data()))
        #expect(try Bencode.decode(Data("4:spam".utf8)) == .string(Data("spam".utf8)))
        let binary = Data([0x00, 0xFF, 0x3A, 0x41])
        #expect(try Bencode.decode("4:\(String(bytes: binary, encoding: .isoLatin1)!)".data(using: .isoLatin1)!) == .string(binary))
    }

    @Test func decodeContainers() throws {
        #expect(try Bencode.decode(Data("l4:spam4:eggse".utf8)) == .list([.string(Data("spam".utf8)), .string(Data("eggs".utf8))]))
        #expect(try Bencode.decode(Data("d3:cow3:moo4:spam4:eggse".utf8)) == .dictionary([
            "cow": .string(Data("moo".utf8)),
            "spam": .string(Data("eggs".utf8)),
        ]))
        #expect(try Bencode.decode(Data("li1eli2eli3eeee".utf8)) == .list([.int(1), .list([.int(2), .list([.int(3)])])]))
    }

    @Test func encodeRoundTrips() throws {
        let values: [BValue] = [
            .int(-1),
            .int(0),
            .string(Data([0x00, 0x01, 0xFE, 0xFF])),
            .list([.int(1), .string(Data("x".utf8)), .list([])]),
            .dictionary(["z": .int(1), "a": .string(Data("b".utf8))]),
        ]
        for value in values {
            #expect(try Bencode.decode(Bencode.encode(value)) == value)
        }
    }

    @Test func encodeSortsDictionaryKeys() {
        let value = BValue.dictionary(["b": .int(1), "a": .int(2)])
        #expect(Bencode.encode(value) == Data("d1:ai2e1:bi1ee".utf8))
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: BencodeError.self) { try Bencode.decode(Data("i-0e".utf8)) }
        #expect(throws: BencodeError.self) { try Bencode.decode(Data("i01e".utf8)) }
        #expect(throws: BencodeError.self) { try Bencode.decode(Data("i42".utf8)) }
        #expect(throws: BencodeError.self) { try Bencode.decode(Data("4spam".utf8)) }
        #expect(throws: BencodeError.self) { try Bencode.decode(Data("x".utf8)) }
        #expect(throws: BencodeError.self) { try Bencode.decode(Data("i1ei2e".utf8)) }
        #expect(throws: BencodeError.self) { try Bencode.decode(Data("5:spam".utf8)) }
    }

    @Test func rejectsExcessiveDepth() {
        let deep = Data(String(repeating: "l", count: 70).utf8) + Data(String(repeating: "e", count: 70).utf8)
        #expect(throws: BencodeError.self) { try Bencode.decode(deep) }
    }

    @Test func rawValueExtractsInfoDict() throws {
        let data = Data("d4:infod3:keyi1e4:name6:foobar6:lengthi123ee7:comment3:hiE".utf8)
        let raw = try Bencode.rawValue(forKey: "info", in: data)
        #expect(String(decoding: raw, as: UTF8.self) == "d3:keyi1e4:name6:foobar6:lengthi123ee")
    }
}
