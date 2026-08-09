import Testing
import Foundation
import TorrentCore
import Streaming

/// A fake `TorrentStreamSource` backed by in-memory bytes with controllable verified ranges,
/// letting tests exercise the HTTP server's progressive-serve behavior deterministically.
actor FakeHTTPStreamSource: TorrentStreamSource {
    let data: Data
    private var verified = Set<Int>()
    private(set) var prioritizeRanges: [Range<Int>] = []

    init(bytes: [UInt8]) {
        self.data = Data(bytes)
    }

    func fileLength(fileIndex: Int) async -> Int { data.count }

    func availability(fileIndex: Int, offset: Int) async -> Int {
        guard offset >= 0, offset < data.count else { return 0 }
        var position = offset
        while position < data.count, verified.contains(position) { position += 1 }
        return position - offset
    }

    func read(fileIndex: Int, offset: Int, length: Int) async -> Data? {
        guard offset >= 0, offset + length <= data.count,
              (offset..<(offset + length)).allSatisfy({ verified.contains($0) }) else { return nil }
        return data.subdata(in: offset..<(offset + length))
    }

    func prioritize(fileIndex: Int, range: Range<Int>) async {
        prioritizeRanges.append(range)
    }

    func verify(_ range: Range<Int>) {
        for byte in range { verified.insert(byte) }
    }

    func prioritizeSnapshot() async -> [Range<Int>] { prioritizeRanges }
}

/// Minimal HTTP client over BSD sockets for the tests.
struct TestHTTPClient {
    static func request(port: UInt16, raw: String) throws -> (status: Int, headers: [String: String], body: Data) {
        let socket = try TCPSocket()
        defer { socket.close() }
        try socket.connect(host: "127.0.0.1", port: port, timeout: 5)
        try socket.send(Data(raw.utf8))

        // Read the head.
        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0D, then: 0x0A) {
            let n = try socket.receive(into: &temp, maxLength: temp.count)
            guard n > 0 else { throw NSError(domain: "http-test", code: -1) }
            buffer.append(contentsOf: temp.prefix(n))
        }
        let head = String(decoding: buffer, as: UTF8.self)
        let lines = head.split(separator: "\r\n")
        guard let statusLine = lines.first, statusLine.split(separator: " ").count >= 2,
              let status = Int(statusLine.split(separator: " ")[1]) else {
            throw NSError(domain: "http-test", code: -2, userInfo: [NSLocalizedDescriptionKey: "bad status: \(head)"])
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        // Read the body according to Content-Length (HEAD has no body).
        var body = Data()
        if !raw.hasPrefix("HEAD"), let len = headers["content-length"].flatMap(Int.init), len > 0 {
            var remaining = len
            while remaining > 0 {
                let n = try socket.receive(into: &temp, maxLength: min(temp.count, remaining))
                guard n > 0 else { throw NSError(domain: "http-test", code: -3) }
                body.append(contentsOf: temp.prefix(n))
                remaining -= n
            }
        }
        return (status, headers, body)
    }
}

@Suite struct TorrentHTTPServerTests {
    private let bytes: [UInt8] = Array(0..<200_000).map { UInt8($0 % 251) }

    @Test func headReturnsFullLength() async throws {
        let source = FakeHTTPStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let server = try TorrentHTTPServer(source: source, fileIndex: 0, path: "movie.mkv")
        server.start()
        defer { server.stop() }

        let response = try TestHTTPClient.request(port: server.port, raw: "HEAD /movie.mkv HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(response.status == 200)
        #expect(response.headers["content-length"] == "\(bytes.count)")
        #expect(response.headers["accept-ranges"] == "bytes")
        #expect(response.body.isEmpty)
    }

    @Test func getReturnsWholeFile() async throws {
        let source = FakeHTTPStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let server = try TorrentHTTPServer(source: source, fileIndex: 0, path: "movie.mkv")
        server.start()
        defer { server.stop() }

        let response = try TestHTTPClient.request(port: server.port, raw: "GET /movie.mkv HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(response.status == 200)
        #expect(response.body == Data(bytes))
    }

    @Test func byteRangeReturnsPartialContent() async throws {
        let source = FakeHTTPStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let server = try TorrentHTTPServer(source: source, fileIndex: 0, path: "movie.mkv")
        server.start()
        defer { server.stop() }

        let response = try TestHTTPClient.request(port: server.port, raw: "GET /movie.mkv HTTP/1.1\r\nHost: localhost\r\nRange: bytes=1000-1999\r\n\r\n")
        #expect(response.status == 206)
        #expect(response.body == Data(bytes[1000..<2000]))
        #expect(response.headers["content-range"] == "bytes 1000-1999/\(bytes.count)")
    }

    @Test func openEndedRangeGoesToEnd() async throws {
        let source = FakeHTTPStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let server = try TorrentHTTPServer(source: source, fileIndex: 0, path: "movie.mkv")
        server.start()
        defer { server.stop() }

        let start = bytes.count - 500
        let response = try TestHTTPClient.request(port: server.port, raw: "GET /movie.mkv HTTP/1.1\r\nHost: localhost\r\nRange: bytes=\(start)-\r\n\r\n")
        #expect(response.status == 206)
        #expect(response.body == Data(bytes[start...]))
    }

    @Test func suffixRangeReturnsLastBytes() async throws {
        let source = FakeHTTPStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let server = try TorrentHTTPServer(source: source, fileIndex: 0, path: "movie.mkv")
        server.start()
        defer { server.stop() }

        let response = try TestHTTPClient.request(port: server.port, raw: "GET /movie.mkv HTTP/1.1\r\nHost: localhost\r\nRange: bytes=-1000\r\n\r\n")
        #expect(response.status == 206)
        #expect(response.body == Data(bytes[(bytes.count - 1000)...]))
    }

    @Test func unsatisfiableRangeReturns416() async throws {
        let source = FakeHTTPStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let server = try TorrentHTTPServer(source: source, fileIndex: 0, path: "movie.mkv")
        server.start()
        defer { server.stop() }

        let response = try TestHTTPClient.request(port: server.port, raw: "GET /movie.mkv HTTP/1.1\r\nHost: localhost\r\nRange: bytes=999999999-\r\n\r\n")
        #expect(response.status == 416)
    }

    @Test func servesProgressivelyAsBytesVerify() async throws {
        let source = FakeHTTPStreamSource(bytes: bytes)
        // Verify only a prefix; a GET for a bounded range within it must serve those bytes and
        // not hang on the rest (the unbounded-whole-file case is covered by the full-file test).
        await source.verify(0..<64 * 1024)
        let server = try TorrentHTTPServer(source: source, fileIndex: 0, path: "movie.mkv")
        server.start()
        defer { server.stop() }

        let response = try TestHTTPClient.request(port: server.port, raw: "GET /movie.mkv HTTP/1.1\r\nHost: localhost\r\nRange: bytes=0-4095\r\n\r\n")
        #expect(response.status == 206)
        #expect(response.body == Data(bytes[0..<4096]))
    }

    @Test func prioritizeRequestsFollowClient() async throws {
        let source = FakeHTTPStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let server = try TorrentHTTPServer(source: source, fileIndex: 0, path: "movie.mkv")
        server.start()
        defer { server.stop() }

        _ = try TestHTTPClient.request(port: server.port, raw: "GET /movie.mkv HTTP/1.1\r\nHost: localhost\r\nRange: bytes=100000-110000\r\n\r\n")
        let ranges = await source.prioritizeSnapshot()
        #expect(ranges.contains { $0.lowerBound == 100000 })
    }
}
