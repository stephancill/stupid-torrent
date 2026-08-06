import Foundation

public enum PeerStreamError: Error, Sendable {
    case closed
    case timeout
}

/// A length-buffered byte stream over a BSD TCP socket. Reads are sequential and
/// `read(exactly:)` blocks until the requested byte count is available. A background reader
/// thread fills the buffer so `read(exactly:)` can suspend until enough bytes arrive.
public final class PeerStream: @unchecked Sendable {
    private let socket: TCPSocket
    private let host: String
    private let port: UInt16
    private let lock = NSLock()
    private var buffer = Data()
    private var pendingRead: (count: Int, continuation: CheckedContinuation<Data, Error>)?
    private var closed = false
    private var readerThread: Thread?

    public init(host: String, port: UInt16) throws {
        self.socket = try TCPSocket()
        self.host = host
        self.port = port
    }

    public init(fd: Int32) {
        self.socket = TCPSocket(fd: fd)
        self.host = "accepted"
        self.port = 0
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .utility) { [weak self] in
                guard let self else {
                    continuation.resume(throwing: PeerStreamError.closed)
                    return
                }
                do {
                    try self.socket.connect(host: self.host, port: self.port, timeout: 10)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        startReader()
    }

    /// For accepted connections the socket is already connected.
    public func start() {
        startReader()
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .utility) { [weak self] in
                guard let self else {
                    continuation.resume(throwing: PeerStreamError.closed)
                    return
                }
                do {
                    try self.socket.send(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func read(exactly count: Int) async throws -> Data {
        if count == 0 { return Data() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: PeerStreamError.closed)
                return
            }
            if buffer.count >= count {
                let chunk = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                lock.unlock()
                continuation.resume(returning: chunk)
                return
            }
            pendingRead = (count, continuation)
            lock.unlock()
        }
    }

    public func close() {
        lock.lock()
        closed = true
        let pending = pendingRead
        pendingRead = nil
        lock.unlock()
        if let pending {
            pending.continuation.resume(throwing: PeerStreamError.closed)
        }
        socket.close()
    }

    private func startReader() {
        let thread = Thread { [weak self] in
            self?.readerLoop()
        }
        thread.name = "peer-reader"
        readerThread = thread
        thread.start()
    }

    private func readerLoop() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count: Int
            do {
                count = try chunk.withUnsafeMutableBytes { raw in
                    try socket.receive(into: raw.baseAddress!, maxLength: raw.count)
                }
            } catch {
                fail(error)
                return
            }
            if count == 0 {
                fail(PeerStreamError.closed)
                return
            }
            appendData(Data(chunk[0..<count]))
        }
    }

    private func appendData(_ data: Data) {
        lock.lock()
        buffer.append(data)
        if let pending = pendingRead, buffer.count >= pending.count {
            pendingRead = nil
            let chunk = Data(buffer.prefix(pending.count))
            buffer.removeFirst(pending.count)
            lock.unlock()
            pending.continuation.resume(returning: chunk)
        } else {
            lock.unlock()
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        closed = true
        let pending = pendingRead
        pendingRead = nil
        lock.unlock()
        if let pending {
            pending.continuation.resume(throwing: error)
        }
        socket.close()
    }
}
