import Foundation

public enum PeerStreamError: Error, Sendable {
    case closed
    case timeout
}

/// A byte-stream transport for a peer connection (TCP via `PeerStream`, µTP via `UTPStream`).
/// `PeerSession` runs the BitTorrent protocol over whichever transport it's given.
public protocol PeerTransport: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func read(exactly count: Int) async throws -> Data
    func close()
}

/// A length-buffered byte stream over a BSD TCP socket. Reads are sequential and
/// `read(exactly:)` blocks until the requested byte count is available. A background reader
/// thread fills the buffer so `read(exactly:)` can suspend until enough bytes arrive.
public final class PeerStream: @unchecked Sendable, PeerTransport {
    private let socket: TCPSocket
    private let host: String
    private let port: UInt16
    private let lock = NSLock()
    private var buffer = Data()
    private var pendingRead: (count: Int, continuation: CheckedContinuation<Data, Error>)?
    private var closed = false
    private var readerThread: Thread?
    /// Encrypt/decrypt transforms installed after the MSE/PE handshake (BEP 10).
    private var encryptTransform: ((Data) -> Data)?
    private var decryptTransform: ((Data) -> Data)?
    private var transformLock = NSLock()

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

    /// Installs encryption for the payload stream. After this, all bytes sent are encrypted and
    /// all bytes received are decrypted before being buffered. Any bytes already buffered (sent by
    /// the peer right after the MSE handshake) are decrypted in place.
    public func enableEncryption(encrypt: @escaping (Data) -> Data, decrypt: @escaping (Data) -> Data) {
        transformLock.lock()
        decryptTransform = decrypt
        encryptTransform = encrypt
        // Re-process anything already buffered (it arrived before the transforms were installed).
        lock.lock()
        if !buffer.isEmpty {
            buffer = decrypt(buffer)
            if let pending = pendingRead, buffer.count >= pending.count {
                pendingRead = nil
                let chunk = Data(buffer.prefix(pending.count))
                buffer.removeFirst(pending.count)
                lock.unlock()
                transformLock.unlock()
                pending.continuation.resume(returning: chunk)
                return
            }
        }
        lock.unlock()
        transformLock.unlock()
    }

    public func connect(timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .utility) { [weak self] in
                guard let self else {
                    continuation.resume(throwing: PeerStreamError.closed)
                    return
                }
                do {
                    try self.socket.connect(host: self.host, port: self.port, timeout: timeout)
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
        let payload = currentEncryptTransform?(data) ?? data
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .utility) { [weak self] in
                guard let self else {
                    continuation.resume(throwing: PeerStreamError.closed)
                    return
                }
                do {
                    try self.socket.send(payload)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous accessor for the encrypt transform (avoids NSLock calls in async contexts).
    private var currentEncryptTransform: ((Data) -> Data)? {
        transformLock.lock()
        defer { transformLock.unlock() }
        return encryptTransform
    }

    /// Synchronous accessor for the decrypt transform.
    private var currentDecryptTransform: ((Data) -> Data)? {
        transformLock.lock()
        defer { transformLock.unlock() }
        return decryptTransform
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

    /// Reads bytes one at a time until `pattern` appears at the tail, consuming it. The bytes
    /// before the pattern are discarded (used for MSE/PE sync). Throws if more than `maxBytes`
    /// are consumed without finding the pattern.
    public func readUntil(pattern: Data, maxBytes: Int) async throws {
        var accumulated = Data()
        while accumulated.count < maxBytes + pattern.count {
            let byte = try await read(exactly: 1)
            accumulated.append(byte)
            if accumulated.count >= pattern.count, accumulated.suffix(pattern.count) == pattern {
                return
            }
        }
        throw PeerStreamError.closed
    }

    /// Puts `data` back at the front of the read buffer (for MSE plaintext fallback detection).
    public func unread(_ data: Data) {
        lock.lock()
        buffer = data + buffer
        lock.unlock()
    }

    /// Injects already-decrypted bytes into the read buffer (used for the MSE IA payload).
    public func injectDecrypted(_ data: Data) {
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
        let transform = currentDecryptTransform
        let decrypted = transform?(data) ?? data
        lock.lock()
        buffer.append(decrypted)
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
