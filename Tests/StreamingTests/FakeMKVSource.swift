import Foundation
@testable import Streaming

actor FakeMKVSource: TorrentStreamSource {
    let data: Data
    private var verified = IndexSet()
    private(set) var prioritizeRanges: [Range<Int>] = []
    private(set) var readRanges: [Range<Int>] = []

    init(_ data: Data) {
        self.data = data
    }

    func fileLength(fileIndex: Int) async -> Int { data.count }

    func availability(fileIndex: Int, offset: Int) async -> Int {
        guard offset >= 0, offset < data.count,
              let range = verified.rangeView.first(where: { $0.contains(offset) }) else { return 0 }
        return range.upperBound - offset
    }

    func read(fileIndex: Int, offset: Int, length: Int) async -> Data? {
        guard offset >= 0, offset + length <= data.count,
              verified.contains(integersIn: offset..<offset + length) else { return nil }
        readRanges.append(offset..<offset + length)
        return data.subdata(in: offset..<offset + length)
    }

    func prioritize(fileIndex: Int, range: Range<Int>) async {
        prioritizeRanges.append(range)
    }

    func verify(_ range: Range<Int>) {
        verified.insert(integersIn: range)
    }
}
