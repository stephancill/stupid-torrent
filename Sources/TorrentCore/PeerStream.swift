import Foundation

public enum PeerStreamError: Error, Sendable {
    case closed
    case timeout
}

public protocol PeerTransport: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func read(exactly count: Int) async throws -> Data
    func close()
}

public final class PeerStream: @unchecked Sendable, PeerTransport {
    private struct PendingRead {
        let count: Int
        let continuation: CheckedContinuation<Data, any Error>
    }

    private struct FulfilledRead {
        let continuation: CheckedContinuation<Data, any Error>
        let data: Data

        func resume() {
            continuation.resume(returning: data)
        }
    }

    private struct PendingWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let socket: TCPSocket
    private let condition = NSCondition()
    private var buffer = Data()
    private var pendingRead: PendingRead?
    private var outbox: [PendingWrite] = []
    private var failure: (any Error)?
    private var encryptor: RC4?
    private var decryptor: RC4?

    public init() throws {
        socket = try TCPSocket()
    }

    public init(fd: Int32) {
        socket = TCPSocket(fd: fd)
        startIO()
    }

    public func connect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws {
        let socket = socket
        try await BlockingIO.run(name: "peer-connect") {
            try socket.connect(host: host, port: port, timeout: timeout)
        }
        startIO()
    }

    func enableEncryption(encryptor: RC4, decryptor: RC4) {
        condition.lock()
        self.encryptor = encryptor
        self.decryptor = decryptor
        buffer = decryptor.update(buffer)
        let ready = takeFulfilledRead()
        condition.unlock()
        ready?.resume()
    }

    func unread(_ data: Data) {
        condition.lock()
        buffer = data + buffer
        let ready = takeFulfilledRead()
        condition.unlock()
        ready?.resume()
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            condition.lock()
            if let failure {
                condition.unlock()
                continuation.resume(throwing: failure)
                return
            }
            outbox.append(PendingWrite(data: encryptor?.update(data) ?? data, continuation: continuation))
            condition.signal()
            condition.unlock()
        }
    }

    public func read(exactly count: Int) async throws -> Data {
        if count == 0 { return Data() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            condition.lock()
            pendingRead = PendingRead(count: count, continuation: continuation)
            let ready = takeFulfilledRead()
            let failed = ready == nil ? failure : nil
            if failed != nil { pendingRead = nil }
            condition.unlock()
            if let ready {
                ready.resume()
            } else if let failed {
                continuation.resume(throwing: failed)
            }
        }
    }

    public func close() {
        fail(PeerStreamError.closed)
    }

    private func takeFulfilledRead() -> FulfilledRead? {
        guard let pending = pendingRead, buffer.count >= pending.count else { return nil }
        pendingRead = nil
        let chunk = Data(buffer.prefix(pending.count))
        buffer.removeFirst(pending.count)
        return FulfilledRead(continuation: pending.continuation, data: chunk)
    }

    private func startIO() {
        BlockingIO.spawn(name: "peer-reader") { [self] in readLoop() }
        BlockingIO.spawn(name: "peer-writer") { [self] in writeLoop() }
    }

    private func readLoop() {
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
            guard count > 0 else {
                fail(PeerStreamError.closed)
                return
            }
            let received = Data(chunk[0..<count])
            condition.lock()
            buffer.append(decryptor?.update(received) ?? received)
            let ready = takeFulfilledRead()
            condition.unlock()
            ready?.resume()
        }
    }

    private func writeLoop() {
        while let write = nextWrite() {
            do {
                try socket.send(write.data)
                write.continuation.resume()
            } catch {
                write.continuation.resume(throwing: error)
                fail(error)
            }
        }
    }

    private func nextWrite() -> PendingWrite? {
        condition.lock()
        defer { condition.unlock() }
        while outbox.isEmpty, failure == nil {
            condition.wait()
        }
        guard failure == nil else { return nil }
        return outbox.removeFirst()
    }

    private func fail(_ error: any Error) {
        condition.lock()
        guard failure == nil else {
            condition.unlock()
            return
        }
        failure = error
        let read = pendingRead
        pendingRead = nil
        let writes = outbox
        outbox.removeAll()
        condition.broadcast()
        condition.unlock()
        read?.continuation.resume(throwing: error)
        writes.forEach { $0.continuation.resume(throwing: error) }
        socket.close()
    }
}
