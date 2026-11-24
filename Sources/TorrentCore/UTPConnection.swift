import Foundation

public actor UTPConnection: PeerTransport {
    public enum UTPError: Swift.Error, Sendable {
        case closed
        case reset
        case timeout
        case notConnected
    }

    nonisolated public let remote: PeerAddress
    nonisolated public let recvID: UInt16
    nonisolated public let sendID: UInt16

    private let transport: UTPTransport
    private let seqNr = UInt16.random(in: 0...UInt16.max)
    private let retransmitInterval = Duration.milliseconds(1000)
    private let rcvWindow: UInt32 = 256 * 1024
    private let maxPayload = UTP.maxPacketSize - UTP.headerSize
    private var state: UTP.ConnectionState
    private var nextSendSeq: UInt16
    private var ackNr: UInt16 = 0

    private var outBuffer: [UInt16: Data] = [:]
    private var outOrder: [UInt16] = []
    private var outSentAt: [UInt16: ContinuousClock.Instant] = [:]

    private var nextRecvSeq = UInt16.random(in: 0...UInt16.max)
    private var inBuffer: [UInt16: Data] = [:]
    private var received = Data()
    private var eofSeq: UInt16?
    private var readClosed = false
    private var ackPending = false
    private var pendingRead: (count: Int, continuation: CheckedContinuation<Data, any Swift.Error>)?

    init(transport: UTPTransport, remote: PeerAddress, recvID: UInt16, sendID: UInt16, isInitiator: Bool) {
        self.transport = transport
        self.remote = remote
        self.recvID = recvID
        self.sendID = sendID
        state = isInitiator ? .synSent : .synRecv
        nextSendSeq = seqNr
    }

    public func startAsInitiator(timeout: Duration = .seconds(10)) async throws {
        state = .synSent
        let syn = UTP.Packet(type: .syn, connectionID: recvID, timestamp: 0, replyMicro: 0, windowSize: rcvWindow, seqNr: seqNr, ackNr: ackNr)
        let deadline = ContinuousClock.now + timeout
        while state != .connected {
            try transport.send(UTP.encode(syn), to: remote)
            if ContinuousClock.now > deadline { throw UTPError.timeout }
            try await Task.sleep(for: .milliseconds(500))
        }
        nextSendSeq = seqNr &+ 1
    }

    public func send(_ data: Data) async throws {
        guard state == .connected else { throw UTPError.notConnected }
        var offset = 0
        while offset < data.count {
            let chunkLength = min(maxPayload, data.count - offset)
            outBuffer[nextSendSeq] = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + chunkLength))
            outOrder.append(nextSendSeq)
            nextSendSeq = nextSendSeq &+ 1
            offset += chunkLength
        }
        flushData()
    }

    public func read(exactly count: Int) async throws -> Data {
        if count == 0 { return Data() }
        if state == .reset { throw UTPError.reset }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Swift.Error>) in
            pendingRead = (count, continuation)
            deliverPendingRead()
        }
    }

    nonisolated public func close() {
        Task { await shutdown() }
    }

    func accept(packet: UTP.Packet) {
        state = .synRecv
        ackNr = packet.seqNr
        nextRecvSeq = packet.seqNr &+ 1
        let synAck = UTP.Packet(type: .state, connectionID: sendID, timestamp: packet.timestamp, replyMicro: 0, windowSize: rcvWindow, seqNr: seqNr, ackNr: ackNr)
        try? transport.send(UTP.encode(synAck), to: remote)
    }

    func nudge() {
        guard state == .connected else { return }
        let now = ContinuousClock.now
        for seq in outOrder {
            guard let payload = outBuffer[seq], let lastSent = outSentAt[seq], now - lastSent >= retransmitInterval else { continue }
            sendDataPacket(seq: seq, payload: payload)
            outSentAt[seq] = now
        }
        if ackPending {
            ackPending = false
            sendState()
        }
    }

    func receive(packet: UTP.Packet) {
        switch packet.type {
        case .syn:
            return
        case .state:
            processAck(packet.ackNr, sack: packet.sack)
            if state == .synSent {
                ackNr = packet.seqNr &- 1
                nextRecvSeq = packet.seqNr
                state = .connected
            }
            flush()
        case .data, .fin:
            processAck(packet.ackNr, sack: packet.sack)
            if state == .synRecv {
                state = .connected
            }
            if state == .connected {
                deliverData(packet)
                ackPending = true
                flush()
            }
        case .reset:
            state = .reset
            fail(UTPError.reset)
        }
    }

    static func seqLE(_ a: UInt16, _ b: UInt16) -> Bool {
        Int16(bitPattern: a &- b) <= 0
    }

    static func seqGT(_ a: UInt16, _ b: UInt16) -> Bool {
        Int16(bitPattern: a &- b) > 0
    }

    private func shutdown() async {
        state = .reset
        fail(UTPError.closed)
        await transport.unregister(self)
    }

    private func processAck(_ ack: UInt16, sack: [UInt8]?) {
        while let first = outOrder.first, Self.seqLE(first, ack) {
            outBuffer.removeValue(forKey: first)
            outSentAt.removeValue(forKey: first)
            outOrder.removeFirst()
        }
        guard let sack, !outOrder.isEmpty else { return }
        for index in 0..<min(sack.count * 8, 1024) where sack[index / 8] & (1 << (7 - (index % 8))) != 0 {
            let seq = ack &+ UInt16(index + 2)
            if outBuffer.removeValue(forKey: seq) != nil {
                outOrder.removeAll { $0 == seq }
                outSentAt.removeValue(forKey: seq)
            }
        }
    }

    private func deliverData(_ packet: UTP.Packet) {
        let seq = packet.seqNr
        if packet.type == .fin { eofSeq = seq }
        if seq == nextRecvSeq {
            var payload: Data? = packet.payload
            while let chunk = payload {
                received.append(chunk)
                if eofSeq == nextRecvSeq { readClosed = true }
                nextRecvSeq = nextRecvSeq &+ 1
                payload = inBuffer.removeValue(forKey: nextRecvSeq)
            }
            ackNr = nextRecvSeq &- 1
        } else if Self.seqGT(seq, nextRecvSeq), inBuffer.count < 1024 {
            inBuffer[seq] = packet.payload
        }
        deliverPendingRead()
    }

    private func deliverPendingRead() {
        guard let pending = pendingRead else { return }
        if received.count >= pending.count {
            pendingRead = nil
            let chunk = Data(received.prefix(pending.count))
            received.removeFirst(pending.count)
            pending.continuation.resume(returning: chunk)
        } else if readClosed {
            pendingRead = nil
            pending.continuation.resume(throwing: UTPError.closed)
        }
    }

    private func flush() {
        let sentData = flushData()
        if ackPending {
            ackPending = false
            if !sentData {
                sendState()
            }
        }
    }

    @discardableResult
    private func flushData() -> Bool {
        guard state == .connected else { return false }
        var sentAny = false
        for seq in outOrder {
            guard let payload = outBuffer[seq], outSentAt[seq] == nil else { continue }
            sendDataPacket(seq: seq, payload: payload)
            outSentAt[seq] = ContinuousClock.now
            sentAny = true
        }
        return sentAny
    }

    private func sendDataPacket(seq: UInt16, payload: Data) {
        let packet = UTP.Packet(type: .data, connectionID: sendID, timestamp: 0, replyMicro: 0, windowSize: rcvWindow, seqNr: seq, ackNr: ackNr, payload: payload)
        try? transport.send(UTP.encode(packet), to: remote)
    }

    private func sendState() {
        let packet = UTP.Packet(type: .state, connectionID: sendID, timestamp: 0, replyMicro: 0, windowSize: rcvWindow, seqNr: nextSendSeq, ackNr: ackNr, sack: makeSACK())
        try? transport.send(UTP.encode(packet), to: remote)
    }

    private func makeSACK() -> [UInt8]? {
        guard !inBuffer.isEmpty else { return nil }
        var sack = [UInt8](repeating: 0, count: 128)
        var maxBit = 0
        for seq in inBuffer.keys {
            let index = Int(seq &- (ackNr &+ 2))
            if index < sack.count * 8 {
                sack[index / 8] |= 1 << (7 - (index % 8))
                maxBit = max(maxBit, index + 1)
            }
        }
        return Array(sack.prefix((maxBit + 7) / 8))
    }

    private func fail(_ error: any Swift.Error) {
        guard let pending = pendingRead else { return }
        pendingRead = nil
        pending.continuation.resume(throwing: error)
    }
}
