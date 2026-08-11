import Foundation
import TorrentCore

final class HLSLoopbackServer: @unchecked Sendable {
    private struct Resource: Sendable {
        let data: Data
        let contentType: String
    }

    private let stream: MKVHLSStream
    private let listener: TCPListener
    private let token = UUID().uuidString
    private let lock = NSLock()
    private var acceptTask: Task<Void, Never>?
    private var sockets: [ObjectIdentifier: TCPSocket] = [:]

    let playlistURL: URL

    var port: UInt16 { listener.port }

    init(stream: MKVHLSStream) throws {
        self.stream = stream
        listener = try TCPListener(port: 0, loopbackOnly: true)
        playlistURL = URL(string: "http://127.0.0.1:\(listener.port)/\(token)/index.m3u8")!
    }

    deinit {
        stop()
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard acceptTask == nil else { return }
        acceptTask = Task { [weak self] in await self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        let task = acceptTask
        acceptTask = nil
        let activeSockets = Array(sockets.values)
        sockets.removeAll()
        lock.unlock()
        task?.cancel()
        listener.close()
        activeSockets.forEach { $0.close() }
    }

    private func acceptLoop() async {
        while !Task.isCancelled {
            do {
                let descriptor = try await Self.blocking { [listener] in try listener.accept() }
                let socket = TCPSocket(fd: descriptor)
                if Task.isCancelled {
                    socket.close()
                    return
                }
                register(socket)
                Task { [weak self] in
                    await self?.serve(socket)
                    self?.unregister(socket)
                    socket.close()
                }
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func serve(_ socket: TCPSocket) async {
        do {
            let request = try await Self.blocking { try HTTPRequest.read(from: socket) }
            guard request.method == "GET" || request.method == "HEAD" else {
                try await send(status: 405, reason: "Method Not Allowed", data: Data(), contentType: "text/plain", request: request, socket: socket)
                return
            }
            let resource = try await resource(for: request.path, socket: socket)
            try await send(status: 200, reason: "OK", data: resource.data, contentType: resource.contentType, request: request, socket: socket)
        } catch HTTPServerError.notFound {
            try? await sendSimple(status: 404, reason: "Not Found", socket: socket)
        } catch HTTPServerError.closed {
            return
        } catch {
            try? await sendSimple(status: 500, reason: "Internal Server Error", socket: socket)
        }
    }

    private func resource(for path: String, socket: TCPSocket) async throws -> Resource {
        let cleanPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let prefix = "/\(token)/"
        guard cleanPath.hasPrefix(prefix) else { throw HTTPServerError.notFound }
        let route = String(cleanPath.dropFirst(prefix.count))
        return try await withThrowingTaskGroup(of: Resource?.self) { group in
            group.addTask { [stream] in
                switch route {
                case "index.m3u8":
                    return Resource(data: try await stream.playlistData(), contentType: "application/vnd.apple.mpegurl")
                case "init.mp4":
                    return Resource(data: try await stream.initializationSegment(), contentType: "video/mp4")
                default:
                    guard route.hasPrefix("segments/"), route.hasSuffix(".m4s"),
                          let id = Int(route.dropFirst("segments/".count).dropLast(".m4s".count)) else {
                        throw HTTPServerError.notFound
                    }
                    return Resource(data: try await stream.mediaSegment(id: id), contentType: "video/iso.segment")
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    if socket.isPeerClosed() { throw HTTPServerError.closed }
                    try await Task.sleep(for: .milliseconds(100))
                }
                return nil
            }
            guard let first = try await group.next(), let resource = first else {
                throw HTTPServerError.closed
            }
            group.cancelAll()
            return resource
        }
    }

    private func send(
        status: Int,
        reason: String,
        data: Data,
        contentType: String,
        request: HTTPRequest,
        socket: TCPSocket
    ) async throws {
        let range = request.range.flatMap { HTTPRequest.parseRange($0, length: data.count) }
        if request.range != nil, range == nil {
            var response = Data("HTTP/1.1 416 Range Not Satisfiable\r\n".utf8)
            response.append(Data("Content-Range: bytes */\(data.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            let responseData = response
            try await Self.blocking { try socket.send(responseData) }
            return
        }
        let bodyRange = range ?? 0..<data.count
        let responseStatus = range == nil ? "\(status) \(reason)" : "206 Partial Content"
        var headers = Data("HTTP/1.1 \(responseStatus)\r\n".utf8)
        headers.append(Data("Content-Type: \(contentType)\r\n".utf8))
        headers.append(Data("Accept-Ranges: bytes\r\n".utf8))
        headers.append(Data("Content-Length: \(bodyRange.count)\r\n".utf8))
        if range != nil {
            headers.append(Data("Content-Range: bytes \(bodyRange.lowerBound)-\(bodyRange.upperBound - 1)/\(data.count)\r\n".utf8))
        }
        headers.append(Data("Connection: close\r\n\r\n".utf8))
        let headerData = headers
        try await Self.blocking { try socket.send(headerData) }
        if request.method != "HEAD", !bodyRange.isEmpty {
            let body = bodyRange == 0..<data.count ? data : data.subdata(in: bodyRange)
            try await Self.blocking { try socket.send(body) }
        }
    }

    private func sendSimple(status: Int, reason: String, socket: TCPSocket) async throws {
        let data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        try await Self.blocking { try socket.send(data) }
    }

    private func register(_ socket: TCPSocket) {
        lock.lock()
        sockets[ObjectIdentifier(socket)] = socket
        lock.unlock()
    }

    private func unregister(_ socket: TCPSocket) {
        lock.lock()
        sockets.removeValue(forKey: ObjectIdentifier(socket))
        lock.unlock()
    }

    private static func blocking<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum HTTPServerError: Error {
    case closed
    case notFound
    case tooLarge
}

private struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let range: String?

    static func read(from socket: TCPSocket) throws -> HTTPRequest {
        let delimiter = Data("\r\n\r\n".utf8)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: delimiter) == nil {
            let count = try socket.receive(into: &buffer, maxLength: buffer.count)
            guard count > 0 else { throw HTTPServerError.closed }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 16 * 1024 { throw HTTPServerError.tooLarge }
        }
        guard let headEnd = data.range(of: delimiter)?.upperBound else {
            throw HTTPServerError.closed
        }
        let head = String(decoding: data[..<headEnd], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first?.split(separator: " "), requestLine.count >= 2 else {
            throw HTTPServerError.closed
        }
        var range: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == "range" {
                range = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), range: range)
    }

    static func parseRange(_ value: String, length: Int) -> Range<Int>? {
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2, length > 0 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(parts[0]), start >= 0, start < length else { return nil }
        if parts[1].isEmpty { return start..<length }
        guard let inclusiveEnd = Int(parts[1]), inclusiveEnd >= start else { return nil }
        return start..<min(inclusiveEnd + 1, length)
    }
}
