import Foundation
import Testing
@testable import Streaming

@Suite struct DolbyAudioConfigTests {
    @Test func dec3DescribesDependentSubstreamChannels() throws {
        let independent = Self.eac3Frame(frameType: 0, frameBytes: 64, acmod: 7, lfeon: 1, chanmap: nil)
        let dependent = Self.eac3Frame(frameType: 1, frameBytes: 32, acmod: 2, lfeon: 0, chanmap: 0x0200)
        let dec3 = try #require(DolbyAudioConfig.dec3(syncframe: independent + dependent))
        let fields = Self.substreamFields(dec3)
        #expect(fields.acmod == 7)
        #expect(fields.lfeon == 1)
        #expect(fields.dependentCount == 1)
        #expect(fields.channelLocations == 0b10)
        #expect(dec3.count == 6)
    }

    @Test func dec3WithoutDependentSubstreamsKeepsReservedBit() throws {
        let independent = Self.eac3Frame(frameType: 0, frameBytes: 64, acmod: 7, lfeon: 1, chanmap: nil)
        let dec3 = try #require(DolbyAudioConfig.dec3(syncframe: independent))
        let fields = Self.substreamFields(dec3)
        #expect(fields.dependentCount == 0)
        #expect(fields.channelLocations == nil)
        #expect(dec3.count == 5)
    }

    private static func eac3Frame(frameType: Int, frameBytes: Int, acmod: Int, lfeon: Int, chanmap: Int?) -> Data {
        var writer = BitWriter()
        writer.write(0x0B77, bits: 16)
        writer.write(frameType, bits: 2)
        writer.write(0, bits: 3)
        writer.write(frameBytes / 2 - 1, bits: 11)
        writer.write(0, bits: 2)
        writer.write(3, bits: 2)
        writer.write(acmod, bits: 3)
        writer.write(lfeon, bits: 1)
        writer.write(16, bits: 5)
        writer.write(27, bits: 5)
        writer.write(0, bits: 1)
        if let chanmap {
            writer.write(1, bits: 1)
            writer.write(chanmap, bits: 16)
        } else if frameType == 1 {
            writer.write(0, bits: 1)
        }
        var bytes = writer.bytes
        bytes.append(Data(repeating: 0, count: frameBytes - bytes.count))
        return bytes
    }

    private static func substreamFields(_ dec3: Data) -> (acmod: Int, lfeon: Int, dependentCount: Int, channelLocations: Int?) {
        var reader = BitReader(data: dec3)
        reader.skip(bits: 16 + 2 + 5 + 1 + 1 + 3)
        let acmod = reader.read(bits: 3)
        let lfeon = reader.read(bits: 1)
        reader.skip(bits: 3)
        let dependentCount = reader.read(bits: 4)
        let channelLocations = dependentCount > 0 ? reader.read(bits: 9) : nil
        return (acmod, lfeon, dependentCount, channelLocations)
    }
}
