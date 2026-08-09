import Foundation
import TorrentCore

/// Serves a torrent file's verified bytes over loopback HTTP with a real `Content-Length` and
/// byte-range support, for players that need a known size. VLC's Matroska demuxer computes
/// duration/seeking from the stream size and range requests; `VLCMedia(initWithStream:)` reports
/// an unknown size (`UINT64_MAX`) and stalls at 0:00 on anything but tiny files.
///
/// Behavior mirrors the loader/stream: requested ranges are prioritized in the picker, and
/// responses block until the requested bytes are verified. `Content-Length` is always the full
/// file length so the player can compute duration; ranges beyond the verified frontier are served
/// progressively as pieces verify.
public final class TorrentHTTPServer: @unchecked Sendable {
    private let source: any TorrentStreamSource
    private let fileIndex: Int
    private let listener: TCPListener
    private var acceptTask: Task<Void, Never>?
    private var connections: [TCPSocket] = []
    private let lock = NSLock()
    private var fileLength: Int?

    /// Loopback URL the player should be pointed at. `path` should end in the file's extension so
    /// VLC's demuxer selection (and any content-type sniffing) sees it.
    public let url: URL

    public var port: UInt16 { listener.port }

    public init(source: any TorrentStreamSource, fileIndex: Int, path: String) throws {
        self.source = source
        self.fileIndex = fileIndex
        self.listener = try TCPListener(port: 0)
        self.url = URL(string: "http://127.0.0.1:\(listener.port)/\(path)")!
    }

    public func start() {
        lock.lock()
        guard acceptTask == nil else {
            lock.unlock()
            return
        }
        let source = self.source
        let fileIndex = self.fileIndex
        acceptTask = Task { [weak self] in
            let length = await source.fileLength(fileIndex: fileIndex)
            self?.setFileLength(length)
            await self?.acceptLoop()
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        acceptTask?.cancel()
        acceptTask = nil
        let sockets = connections
        connections = []
        lock.unlock()
        sockets.forEach { $0.close() }
        listener.close()
    }

    private func setFileLength(_ length: Int) {
        lock.lock()
        fileLength = length
        lock.unlock()
    }

    private func currentLength() -> Int? {
        lock.lock()
        let value = fileLength
        lock.unlock()
        return value
    }

    private func registerConnection(_ socket: TCPSocket) {
        lock.lock()
        connections.append(socket)
        lock.unlock()
    }

    private func unregisterConnection(_ socket: TCPSocket) {
        lock.lock()
        connections.removeAll { $0 === socket }
        lock.unlock()
    }

    private func acceptLoop() async {
        while !Task.isCancelled {
            let fd: Int32
            do {
                fd = try await acceptConnection()
            } catch {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let socket = TCPSocket(fd: fd)
            registerConnection(socket)
            Task { [weak self] in
                await self?.serve(socket)
                self?.unregisterConnection(socket)
                socket.close()
            }
        }
    }

    private func serve(_ socket: TCPSocket) async {
        // HTTP/1.1 keep-alive: serve multiple requests on one connection until the client closes.
        while !Task.isCancelled {
            guard let request = try? await readRequest(socket) else { return }
            guard let fileLength = currentLength() else { return }

            let plan = responsePlan(for: request, fileLength: fileLength)
            var head = Data()
            head.append(contentsOf: "HTTP/1.1 \(plan.status)\r\n".utf8)
            for (key, value) in plan.headers {
                head.append(contentsOf: "\(key): \(value)\r\n".utf8)
            }
            head.append(contentsOf: "\r\n".utf8)
            guard (try? await send(head, over: socket)) != nil else { return }

            guard !request.isHEAD, plan.status != "416 Requested Range Not Satisfiable" else {
                if plan.status == "416 Requested Range Not Satisfiable" { return }
                continue
            }
            await streamRange(plan.start..<plan.end, over: socket)
            // A full-file response is the natural end; keep serving further requests on this
            // connection (seek-range requests after the initial GET).
        }
    }

    /// Streams verified bytes of `range`, prioritizing it and blocking until each chunk verifies.
    private func streamRange(_ range: Range<Int>, over socket: TCPSocket) async {
        guard !range.isEmpty else { return }
        let chunkSize = 256 * 1024
        let lookahead = 2 * 1024 * 1024
        var offset = range.lowerBound
        let end = range.upperBound

        while offset < end && !Task.isCancelled {
            await source.prioritize(fileIndex: fileIndex, range: offset..<min(offset + lookahead, fileLength ?? end))

            let available = await source.availability(fileIndex: fileIndex, offset: offset)
            if available > 0 {
                let length = min(available, chunkSize, end - offset)
                guard length > 0, let data = await source.read(fileIndex: fileIndex, offset: offset, length: length) else {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                guard (try? await send(data, over: socket)) != nil else { return }
                offset += data.count
                continue
            }
            // Not verified yet: block until it is (the player waits on the socket read).
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func responsePlan(
        for request: HTTPRequest,
        fileLength: Int
    ) -> (status: String, headers: [(String, String)], start: Int, end: Int) {
        var start = 0
        var end = fileLength
        var ranged = false

        if let spec = request.rangeSpec {
            let parsed = HTTPRequest.parseRange(spec, fileLength: fileLength)
            switch parsed {
            case .some(let range):
                start = range.lowerBound
                end = range.upperBound
                ranged = true
            case .none:
                if spec.hasPrefix("bytes=") {
                    // Unsatisfiable range. Include `Content-Range: bytes */<size>` so clients
                    // (VLC seeks to exact EOF to probe the size) still learn the file length.
                    return ("416 Requested Range Not Satisfiable", [
                        ("Content-Range", "bytes */\(fileLength)"),
                        ("Content-Length", "0"),
                    ], 0, 0)
                }
            }
        }

        // VLC treats a 200 with a full body as a finite stream and stops at EOF (no re-fetch of
        // clusters after a seek). Serve the initial whole-file request as a bounded 206 (the
        // lookahead window) so the input stays open and VLC issues range requests for the rest,
        // which we serve progressively. This mirrors the loader/stream's bounded lookahead.
        if !ranged && !request.isHEAD {
            let lookahead = min(fileLength, 2 * 1024 * 1024)
            if lookahead < fileLength {
                start = 0
                end = lookahead
                ranged = true
            }
        }

        var headers: [(String, String)] = [
            ("Content-Type", "video/x-matroska"),
            ("Accept-Ranges", "bytes"),
            ("Content-Length", "\(end - start)"),
        ]
        // A range covering the whole file is served as a plain 200 (VLC's HTTP input treats the
        // first request's 206+Content-Range inconsistently for duration/seek-table setup).
        let wholeFile = start == 0 && end == fileLength
        if ranged && !wholeFile {
            headers.append(("Content-Range", "bytes \(start)-\(end - 1)/\(fileLength)"))
        }
        let status = ranged && !wholeFile ? "206 Partial Content" : "200 OK"
        return (status, headers, start, end)
    }

    /// Reads the HTTP request head (request line + headers) from the socket.
    private func readRequest(_ socket: TCPSocket) async throws -> HTTPRequest {
        var buffer = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while buffer.range(of: delimiter) == nil {
            let data = try await receive(upTo: 4096, from: socket)
            guard !data.isEmpty else { throw HTTPError.closed }
            buffer.append(data)
            if buffer.count > 64 * 1024 { throw HTTPError.tooLarge }
        }
        guard let end = buffer.range(of: delimiter)?.upperBound else { throw HTTPError.closed }
        let head = String(decoding: buffer[..<end], as: UTF8.self)
        return try HTTPRequest.parse(head)
    }

    private func acceptConnection() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [listener] in
                do {
                    continuation.resume(returning: try listener.accept())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func receive(upTo maxLength: Int, from socket: TCPSocket) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: maxLength)
                do {
                    let count = try socket.receive(into: &buffer, maxLength: maxLength)
                    continuation.resume(returning: Data(buffer.prefix(count)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func send(_ data: Data, over socket: TCPSocket) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try socket.send(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum HTTPError: Error {
    case closed
    case tooLarge
}

private struct HTTPRequest {
    let method: String
    let path: String
    let rangeSpec: String?
    let isHEAD: Bool

    static func parse(_ head: String) throws -> HTTPRequest {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first?.split(separator: " "), requestLine.count >= 2 else {
            throw HTTPError.closed
        }
        let method = String(requestLine[0])
        let path = String(requestLine[1])
        var rangeSpec: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "range", value.lowercased().hasPrefix("bytes=") {
                rangeSpec = value
            }
        }
        return HTTPRequest(method: method, path: path, rangeSpec: rangeSpec, isHEAD: method == "HEAD")
    }

    /// Parses a `bytes=` range spec against a known file length. Returns nil for malformed or
    /// unsatisfiable ranges (caller returns 416 — which VLC's HTTP lib explicitly accepts on seek).
    static func parseRange(_ spec: String, fileLength: Int) -> Range<Int>? {
        let bytes = spec.dropFirst("bytes=".count)
        let parts = bytes.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            // Suffix range "bytes=-N": last N bytes.
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            let start = max(0, fileLength - suffix)
            return start..<fileLength
        }
        guard let start = Int(parts[0]), start >= 0 else { return nil }
        if start >= fileLength { return nil }
        if parts[1].isEmpty {
            // Open-ended "bytes=a-": to end of file.
            return start..<fileLength
        }
        guard let end = Int(parts[1]), end >= start else { return nil }
        return start..<(min(end, fileLength - 1) + 1)
    }
}
