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

enum BSD {
    static func resolveIPv4(_ host: String, port: UInt16) throws -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let ip = inet_addr(host)
        if ip != in_addr_t(INADDR_NONE) {
            addr.sin_addr.s_addr = ip
            return addr
        }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else {
            throw SocketError.resolve(host)
        }
        defer { freeaddrinfo(result) }
        addr.sin_addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }.sin_addr
        return addr
    }

    /// Prevents `write`/`send` on a socket whose peer has closed from raising SIGPIPE (which by
    /// default terminates the process). With `SO_NOSIGPIPE`, the write returns EPIPE and the
    /// caller handles it as a dropped peer — essential for long-running downloads where a peer
    /// can disconnect between the read loop noticing and an in-flight block request write.
    static func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
}

public final class TCPSocket: @unchecked Sendable {
    private var fd: Int32

    public init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }
        BSD.setNoSigPipe(fd)
    }

    public init(fd: Int32) {
        self.fd = fd
        BSD.setNoSigPipe(fd)
    }

    public func connect(host: String, port: UInt16, timeout: TimeInterval) throws {
        var addr = try BSD.resolveIPv4(host, port: port)
        fcntl(fd, F_SETFL, O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc < 0, errno == EINPROGRESS {
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let selected = poll(&pollFD, 1, Int32(timeout * 1000))
            if selected <= 0 {
                fcntl(fd, F_SETFL, 0)
                closeSocket()
                throw SocketError.timeout
            }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
            if soError != 0 {
                fcntl(fd, F_SETFL, 0)
                closeSocket()
                throw SocketError.connect(soError)
            }
        } else if rc < 0 {
            closeSocket()
            throw SocketError.connect(errno)
        }
        fcntl(fd, F_SETFL, 0)
    }

    public func send(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.write(errno)
                }
                if n == 0 { throw SocketError.write(0) }
                sent += n
            }
        }
    }

    public func receive(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        var n: Int
        repeat {
            n = read(fd, buffer, maxLength)
        } while n < 0 && errno == EINTR
        if n < 0 { throw SocketError.read(errno) }
        return n
    }

    public func close() {
        closeSocket()
    }

    private func closeSocket() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit {
        closeSocket()
    }
}

public final class UDPSocket: @unchecked Sendable {
    private var fd: Int32

    public init() throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }
        BSD.setNoSigPipe(fd)
    }

    /// The port the socket is bound to after `bind(port:)` (0 until bound).
    public private(set) var localPort: UInt16 = 0

    /// Binds the socket to a local UDP port so it can receive datagrams (µTP responder / listener).
    public func bind(port requestedPort: UInt16) throws {
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = requestedPort.bigEndian
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw SocketError.bind(errno) }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        localPort = UInt16(bigEndian: bound.sin_port)
    }

    public func send(_ data: Data, to host: String, port: UInt16) throws {
        var addr = try BSD.resolveIPv4(host, port: port)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let rc = withUnsafePointer(to: &addr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, base, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc < 0 { throw SocketError.write(errno) }
        }
    }

    public func receive(timeout: TimeInterval) throws -> Data? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            recv(fd, raw.baseAddress!, raw.count, 0)
        }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
            throw SocketError.read(errno)
        }
        return Data(buffer.prefix(n))
    }

    /// Receives a datagram and the address it came from (µTP needs the sender for demux).
    public func receiveFrom(timeout: TimeInterval) throws -> (data: Data, host: String, port: UInt16)? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            withUnsafeMutablePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd, raw.baseAddress!, raw.count, 0, sockPtr, &addrLen)
                }
            }
        }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
            throw SocketError.read(errno)
        }
        let ipBytes = withUnsafeBytes(of: &addr.sin_addr.s_addr) { Array($0) }
        let host = ipBytes.map { String($0) }.joined(separator: ".")
        let port = UInt16(bigEndian: addr.sin_port)
        return (Data(buffer.prefix(n)), host, port)
    }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit {
        close()
    }
}

public final class TCPListener: @unchecked Sendable {
    private var fd: Int32
    public let port: UInt16

    public init(port requestedPort: UInt16) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw SocketError.create(errno) }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = requestedPort.bigEndian
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw SocketError.bind(errno)
        }
        guard listen(socketFD, 32) == 0 else {
            Darwin.close(socketFD)
            throw SocketError.listen(errno)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        self.fd = socketFD
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    public func accept() throws -> Int32 {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(fd, $0, &length)
            }
        }
        if client < 0 { throw SocketError.accept(errno) }
        return client
    }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit {
        close()
    }
}
