import Foundation
import Darwin

public enum SocketError: Error, Sendable {
    case create(Int32)
    case resolve(String)
    case connect(Int32)
    case timeout
    case write(Int32)
    case read(Int32)
    case bind(Int32)
    case listen(Int32)
    case accept(Int32)
    case closed
}

public struct Datagram: Sendable {
    public let data: Data
    public let sender: PeerAddress
}

final class SocketDescriptor: @unchecked Sendable {
    private static let pollSlice = Duration.milliseconds(250)

    private let lock = NSLock()
    private let fd: Int32
    private var users = 0
    private var closed = false

    convenience init(type: Int32) throws {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }
        self.init(fd: fd)
    }

    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        if !closed { Darwin.close(fd) }
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }

    func use<T>(_ body: (Int32) throws -> T) throws -> T {
        try lock.withLock {
            guard !closed else { throw SocketError.closed }
            users += 1
        }
        defer {
            let release = lock.withLock {
                users -= 1
                return closed && users == 0
            }
            if release { Darwin.close(fd) }
        }
        return try body(fd)
    }

    func close() {
        let release: Bool = lock.withLock {
            guard !closed else { return false }
            closed = true
            guard users == 0 else {
                Darwin.shutdown(fd, SHUT_RDWR)
                return false
            }
            return true
        }
        if release { Darwin.close(fd) }
    }

    func wait(fd: Int32, events: Int32, timeout: TimeInterval?) throws -> Bool {
        let deadline = timeout.map { ContinuousClock.now + .milliseconds(Int($0 * 1000)) }
        while true {
            if isClosed { throw SocketError.closed }
            var slice = Self.pollSlice
            if let deadline {
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { return false }
                slice = min(slice, remaining)
            }
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let milliseconds = Int32(slice.components.seconds * 1000 + slice.components.attoseconds / 1_000_000_000_000_000)
            let result = poll(&descriptor, 1, max(milliseconds, 1))
            if result > 0 { return true }
            if result < 0, errno != EINTR { throw SocketError.read(errno) }
        }
    }
}

enum BSD {
    static func resolveIPv4(host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let ip = inet_addr(host)
        if ip != in_addr_t(INADDR_NONE) {
            address.sin_addr.s_addr = ip
            return address
        }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else {
            throw SocketError.resolve(host)
        }
        defer { freeaddrinfo(result) }
        address.sin_addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        return address
    }

    static func withSockaddr<T>(_ address: sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        try withUnsafePointer(to: address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    static func withMutableSockaddr<T>(_ body: (UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) throws -> T) rethrows -> (T, sockaddr_in) {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, &length) }
        }
        return (result, address)
    }

    static func localPort(fd: Int32) -> UInt16 {
        let (_, bound) = withMutableSockaddr { getsockname(fd, $0, $1) }
        return UInt16(bigEndian: bound.sin_port)
    }

    static func bind(fd: Int32, address: in_addr_t, port: UInt16) throws {
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = address
        local.sin_port = port.bigEndian
        guard withSockaddr(local, { Darwin.bind(fd, $0, $1) }) == 0 else { throw SocketError.bind(errno) }
    }
}

public final class TCPSocket: Sendable {
    private let descriptor: SocketDescriptor

    public init() throws {
        descriptor = try SocketDescriptor(type: SOCK_STREAM)
    }

    public init(fd: Int32) {
        descriptor = SocketDescriptor(fd: fd)
    }

    public func connect(host: String, port: UInt16, timeout: TimeInterval) throws {
        do {
            let address = try BSD.resolveIPv4(host: host, port: port)
            try descriptor.use { fd in
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                defer { _ = fcntl(fd, F_SETFL, 0) }
                guard BSD.withSockaddr(address, { Darwin.connect(fd, $0, $1) }) < 0 else { return }
                guard errno == EINPROGRESS else { throw SocketError.connect(errno) }
                guard try descriptor.wait(fd: fd, events: POLLOUT, timeout: timeout) else { throw SocketError.timeout }
                var soError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
                if soError != 0 { throw SocketError.connect(soError) }
            }
        } catch {
            close()
            throw error
        }
    }

    public func send(_ data: Data) throws {
        try descriptor.use { fd in
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, base.advanced(by: sent), raw.count - sent)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw SocketError.write(errno)
                    }
                    if n == 0 { throw SocketError.write(0) }
                    sent += n
                }
            }
        }
    }

    public func receive(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        try descriptor.use { fd in
            var n: Int
            repeat {
                n = read(fd, buffer, maxLength)
            } while n < 0 && errno == EINTR
            if n < 0 { throw SocketError.read(errno) }
            return n
        }
    }

    public func isPeerClosed() -> Bool {
        (try? descriptor.use { fd in
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            guard poll(&descriptor, 1, 0) > 0 else { return false }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
            guard descriptor.revents & Int16(POLLIN) != 0 else { return false }
            var byte: UInt8 = 0
            return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
        }) ?? true
    }

    public func close() {
        descriptor.close()
    }
}

public final class UDPSocket: Sendable {
    private let descriptor: SocketDescriptor

    public init() throws {
        descriptor = try SocketDescriptor(type: SOCK_DGRAM)
    }

    public var localPort: UInt16 {
        (try? descriptor.use { BSD.localPort(fd: $0) }) ?? 0
    }

    public func bind(port: UInt16) throws {
        try descriptor.use { try BSD.bind(fd: $0, address: INADDR_ANY, port: port) }
    }

    public func send(_ data: Data, to destination: PeerAddress) throws {
        let address = try BSD.resolveIPv4(host: destination.host, port: destination.port)
        try descriptor.use { fd in
            let sent = data.withUnsafeBytes { raw in
                BSD.withSockaddr(address) { sendto(fd, raw.baseAddress, raw.count, 0, $0, $1) }
            }
            if sent < 0 { throw SocketError.write(errno) }
        }
    }

    public func receive(timeout: TimeInterval?) throws -> Datagram? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        return try buffer.withUnsafeMutableBytes { try receive(into: $0, timeout: timeout) }
    }

    public func datagrams(name: String) -> AsyncStream<Datagram> {
        let (stream, continuation) = AsyncStream<Datagram>.makeStream()
        BlockingIO.spawn(name: name) { [self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            buffer.withUnsafeMutableBytes { raw in
                while !descriptor.isClosed {
                    if let datagram = try? receive(into: raw, timeout: nil) {
                        continuation.yield(datagram)
                    }
                }
            }
            continuation.finish()
        }
        return stream
    }

    public func close() {
        descriptor.close()
    }

    private func receive(into buffer: UnsafeMutableRawBufferPointer, timeout: TimeInterval?) throws -> Datagram? {
        try descriptor.use { fd in
            guard try descriptor.wait(fd: fd, events: POLLIN, timeout: timeout) else { return nil }
            let (count, sender) = BSD.withMutableSockaddr {
                recvfrom(fd, buffer.baseAddress, buffer.count, MSG_DONTWAIT, $0, $1)
            }
            guard count >= 0 else {
                if errno == EAGAIN || errno == EINTR { return nil }
                throw SocketError.read(errno)
            }
            return Datagram(data: Data(buffer.prefix(count)), sender: PeerAddress(socketAddress: sender))
        }
    }
}

public final class TCPListener: Sendable {
    private let descriptor: SocketDescriptor
    public let port: UInt16

    public init(port requestedPort: UInt16, loopbackOnly: Bool = false) throws {
        let descriptor = try SocketDescriptor(type: SOCK_STREAM)
        do {
            port = try descriptor.use { fd in
                try BSD.bind(fd: fd, address: loopbackOnly ? inet_addr("127.0.0.1") : INADDR_ANY, port: requestedPort)
                guard listen(fd, 32) == 0 else { throw SocketError.listen(errno) }
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                return BSD.localPort(fd: fd)
            }
        } catch {
            descriptor.close()
            throw error
        }
        self.descriptor = descriptor
    }

    public func accept() throws -> Int32 {
        try descriptor.use { fd in
            while true {
                _ = try descriptor.wait(fd: fd, events: POLLIN, timeout: nil)
                let (client, _) = BSD.withMutableSockaddr { Darwin.accept(fd, $0, $1) }
                if client >= 0 {
                    _ = fcntl(client, F_SETFL, 0)
                    return client
                }
                guard errno == EAGAIN || errno == EINTR || errno == ECONNABORTED else { throw SocketError.accept(errno) }
            }
        }
    }

    public func close() {
        descriptor.close()
    }
}
