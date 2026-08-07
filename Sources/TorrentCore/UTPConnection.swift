import Foundation

/// A single µTP (BEP 29) connection: reliability (seq/ack, retransmit), receive buffering, and
/// flow control. Runs over a shared `UTPTransport` UDP socket. The wire behavior mirrors libutp
/// (`utp_internal.cpp`) closely enough to interoperate: connection-id scheme, SYN consumes a
/// sequence number, SYNACK ack_nr = seq - 1, SACK bit i covers seq (ack_nr + 2 + i), and acks are
/// piggybacked on outbound data or sent as pure STATE packets.
public actor UTPConnection {
    public enum UTPError: Swift.Error, Sendable {
        case closed
        case reset
        case timeout
        case rejected
        case notConnected
    }

    nonisolated public let remote: PeerAddress
    /// connid we RECEIVE packets with (packets from the peer carry this).
    nonisolated public let recvID: UInt16
    /// connid we SEND packets with.
    nonisolated public let sendID: UInt16

    private let transport: UTPTransport
    private var state: UTP.ConnectionState
    /// Initial sequence number, used for the SYN (initiator) and SYNACK (responder).
    private var seqNr: UInt16
    /// Next sequence number for outbound DATA.
    private var nextSendSeq: UInt16
    /// Last contiguous sequence number received from the peer.
    private var ackNr: UInt16

    // Send side (reliability)
    private var outBuffer: [UInt16: Data] = [:]
    private var outOrder: [UInt16] = []
    private var outSentAt: [UInt16: ContinuousClock.Instant] = [:]
    private var lastAcked: UInt16 = 0
    private let retransmitInterval = Duration.milliseconds(1000)
    private let rcvWindow: UInt32 = 256 * 1024
    private let maxPayload = UTP.maxPacketSize - UTP.headerSize

    // Receive side
    private var nextRecvSeq: UInt16
    private var inBuffer: [UInt16: Data] = [:]
    private var receivedOrder: [Data] = []
    private var eofSeq: UInt16?
    private var readClosed = false
    private var ackPending = false
    private var pendingRead: (count: Int, continuation: CheckedContinuation<Data, any Swift.Error>)?

    public init(transport: UTPTransport, remote: PeerAddress, recvID: UInt16, sendID: UInt16, isInitiator: Bool) {
        self.transport = transport
        self.remote = remote
        self.recvID = recvID
        self.sendID = sendID
        self.state = isInitiator ? .synSent : .synRecv
        self.seqNr = UInt16.random(in: 0...UInt16.max)
        self.ackNr = 0
        self.nextSendSeq = seqNr
        self.nextRecvSeq = UInt16.random(in: 0...UInt16.max)
        self.lastAcked = seqNr &- 1
    }

    // MARK: - Connection setup

    /// Initiator path: sends the SYN (connid = recvID, as libutp does) and retransmits it until the
    /// peer's SYNACK transitions us to `.connected`. The SYN consumes a sequence number, so the
    /// first DATA sent is `seqNr + 1`.
    public func startAsInitiator(timeout: Duration = .seconds(10)) async throws {
        state = .synSent
        let syn = UTP.Packet(
            type: .syn,
            connectionID: recvID,
            timestamp: 0,
            replyMicro: 0,
            windowSize: rcvWindow,
            seqNr: seqNr,
            ackNr: ackNr
        )
        let deadline = ContinuousClock.now + timeout
        while state != .connected {
            try await transport.send(UTP.encode(syn), to: remote)
            if ContinuousClock.now > deadline { throw UTPError.timeout }
            try await Task.sleep(for: .milliseconds(500))
        }
        nextSendSeq = seqNr &+ 1
    }

    /// Responder path (called by the transport on a SYN): sends the SYNACK with connid = sendID
    /// and ack_nr = the SYN's seq. The connection becomes `.connected` when the first DATA arrives.
    public func accept(packet: UTP.Packet) async {
        state = .synRecv
        ackNr = packet.seqNr
        // The SYN's seq was received in-order; the initiator's first DATA carries seq_nr + 1.
        nextRecvSeq = packet.seqNr &+ 1
        let synAck = UTP.Packet(
            type: .state,
            connectionID: sendID,
            timestamp: packet.timestamp,
            replyMicro: 0,
            windowSize: rcvWindow,
            seqNr: seqNr,
            ackNr: ackNr
        )
        try? await transport.send(UTP.encode(synAck), to: remote)
    }

    /// Periodic nudge from the transport ticker: retransmit unacked packets past the RTO and flush
    /// any pending ack.
    public func nudge() async {
        guard state == .connected else { return }
        let now = ContinuousClock.now
        for seq in outOrder {
            guard let payload = outBuffer[seq], let lastSent = outSentAt[seq] else { continue }
            if now - lastSent >= retransmitInterval {
                await sendDataPacket(seq: seq, payload: payload)
                outSentAt[seq] = now
            }
        }
        if ackPending {
            ackPending = false
            await sendState()
        }
    }

    // MARK: - Packet processing (from the transport demux)

    public func receive(packet: UTP.Packet) async {
        switch packet.type {
        case .syn:
            // Incoming SYN is handled by the transport (responder creation). Nothing to do here.
            return
        case .state:
            processAck(packet.ackNr, sack: packet.sack)
            if state == .synSent {
                // SYNACK completes the initiator handshake. The SYNACK does not consume a sequence
                // number on the peer's side, so the first peer DATA carries seq_nr = SYNACK.seq_nr
                // and must be treated as in-order: ack_nr = seq_nr - 1 (libutp `utp_process_incoming`).
                ackNr = packet.seqNr &- 1
                nextRecvSeq = packet.seqNr
                state = .connected
            }
            await maybeFlush()
        case .data, .fin:
            processAck(packet.ackNr, sack: packet.sack)
            if state == .synRecv {
                state = .connected
            }
            if state == .connected {
                deliverData(packet)
                ackPending = true
                await maybeFlush()
            }
        case .reset:
            state = .reset
            fail(UTPError.reset)
        }
    }

    private func processAck(_ ack: UInt16, sack: [UInt8]?) {
        // Cumulative ack: drop everything up to and including `ack`.
        while let first = outOrder.first, Self.seqLE(first, ack) {
            outBuffer.removeValue(forKey: first)
            outSentAt.removeValue(forKey: first)
            outOrder.removeFirst()
        }
        if Self.seqGT(ack, lastAcked) { lastAcked = ack }
        // Selective acks: bit i covers seq (ack + 2 + i) — bit 0 is the hole at ack+1.
        if let sack, !outOrder.isEmpty {
            let bitCount = min(sack.count * 8, 1024)
            for index in 0..<bitCount {
                let byte = sack[index / 8]
                let mask: UInt8 = 1 << (7 - (index % 8))
                if byte & mask != 0 {
                    let seq = ack &+ UInt16(index + 2)
                    if outBuffer.removeValue(forKey: seq) != nil {
                        outOrder.removeAll { $0 == seq }
                        outSentAt.removeValue(forKey: seq)
                    }
                }
            }
        }
    }

    private func deliverData(_ packet: UTP.Packet) {
        let seq = packet.seqNr
        if packet.isFIN { eofSeq = seq }
        if seq == nextRecvSeq {
            if packet.isFIN || !packet.payload.isEmpty {
                receivedOrder.append(packet.payload)
            }
            if eofSeq == nextRecvSeq { readClosed = true }
            nextRecvSeq = nextRecvSeq &+ 1
            while let buffered = inBuffer.removeValue(forKey: nextRecvSeq) {
                receivedOrder.append(buffered)
                if eofSeq == nextRecvSeq { readClosed = true }
                nextRecvSeq = nextRecvSeq &+ 1
            }
            // ack_nr = last contiguous sequence number received.
            ackNr = nextRecvSeq &- 1
        } else if Self.seqGT(seq, nextRecvSeq) && inBuffer.count < 1024 {
            inBuffer[seq] = packet.payload
        }
        tryDeliverPending()
    }

    /// Flushes buffered outbound data (piggybacking the current ack) and, if no data was sent,
    /// sends a pure STATE ack when one is due.
    private func maybeFlush() async {
        let sentData = await flushData()
        if ackPending {
            ackPending = false
            if !sentData {
                await sendState()
            }
        }
    }

    /// Sends all buffered-but-unsent DATA packets once. Returns true if any packet was sent.
    @discardableResult
    public func flushData() async -> Bool {
        guard state == .connected else { return false }
        var sentAny = false
        for seq in outOrder {
            guard let payload = outBuffer[seq], outSentAt[seq] == nil else { continue }
            await sendDataPacket(seq: seq, payload: payload)
            outSentAt[seq] = ContinuousClock.now
            sentAny = true
        }
        return sentAny
    }

    private func sendDataPacket(seq: UInt16, payload: Data) async {
        let packet = UTP.Packet(
            type: .data,
            connectionID: sendID,
            timestamp: 0,
            replyMicro: 0,
            windowSize: rcvWindow,
            seqNr: seq,
            ackNr: ackNr,
            payload: payload
        )
        try? await transport.send(UTP.encode(packet), to: remote)
    }

    /// Sends a pure STATE (ack) packet, with a SACK extension when there are out-of-order
    /// packets to report. libutp attaches SACK only to STATE packets.
    public func sendState() async {
        let packet = UTP.Packet(
            type: .state,
            connectionID: sendID,
            timestamp: 0,
            replyMicro: 0,
            windowSize: rcvWindow,
            seqNr: nextSendSeq,
            ackNr: ackNr,
            sack: makeSACK()
        )
        try? await transport.send(UTP.encode(packet), to: remote)
    }

    private func makeSACK() -> [UInt8]? {
        guard !inBuffer.isEmpty else { return nil }
        var sack = [UInt8](repeating: 0, count: 128)
        var maxBit = 0
        for (seq, _) in inBuffer {
            let index = Int(seq &- (ackNr &+ 2))
            if index >= 0 && index < sack.count * 8 {
                sack[index / 8] |= 1 << (7 - (index % 8))
                maxBit = max(maxBit, index + 1)
            }
        }
        return Array(sack.prefix((maxBit + 7) / 8))
    }

    // MARK: - Send / read

    /// Queues `data` into the retransmit buffer and sends it (fragmented into µTP packets).
    public func write(_ data: Data) async throws -> Int {
        guard state == .connected else { throw UTPError.notConnected }
        var offset = 0
        while offset < data.count {
            let chunkLength = min(maxPayload, data.count - offset)
            let seq = nextSendSeq
            outBuffer[seq] = data.subdata(in: offset..<(offset + chunkLength))
            outOrder.append(seq)
            nextSendSeq = nextSendSeq &+ 1
            offset += chunkLength
        }
        await flushData()
        return data.count
    }

    /// Reads exactly `count` contiguous bytes, suspending until they arrive or the connection
    /// closes. `count == 0` returns immediately.
    public func read(exactly count: Int) async throws -> Data {
        if count == 0 { return Data() }
        if state == .reset { throw UTPError.reset }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Swift.Error>) in
            if takeAvailable(count, into: continuation) { return }
            if readClosed {
                continuation.resume(throwing: UTPError.closed)
                return
            }
            pendingRead = (count, continuation)
        }
    }

    private func takeAvailable(_ count: Int, into continuation: CheckedContinuation<Data, any Swift.Error>) -> Bool {
        let available = receivedOrder.reduce(0) { $0 + $1.count }
        guard available >= count else { return false }
        var data = Data()
        var needed = count
        while needed > 0, !receivedOrder.isEmpty {
            let chunk = receivedOrder[0]
            if chunk.count <= needed {
                data.append(chunk)
                needed -= chunk.count
                receivedOrder.removeFirst()
            } else {
                data.append(chunk.prefix(needed))
                receivedOrder[0] = chunk.dropFirst(needed)
                needed = 0
            }
        }
        continuation.resume(returning: data)
        return true
    }

    private func tryDeliverPending() {
        guard let pending = pendingRead else { return }
        if takeAvailable(pending.count, into: pending.continuation) {
            pendingRead = nil
        } else if readClosed {
            pendingRead = nil
            pending.continuation.resume(throwing: UTPError.closed)
        }
    }

    public func sendFIN() async throws {
        guard state == .connected else { return }
        let seq = nextSendSeq
        nextSendSeq = nextSendSeq &+ 1
        let packet = UTP.Packet(
            type: .fin,
            connectionID: sendID,
            timestamp: 0,
            replyMicro: 0,
            windowSize: rcvWindow,
            seqNr: seq,
            ackNr: ackNr
        )
        try await transport.send(UTP.encode(packet), to: remote)
        state = .reset
    }

    /// Local teardown: unblocks any pending read with `.closed` and marks the connection reset.
    public func close() {
        state = .reset
        fail(UTPError.closed)
    }

    /// Removes the connection from the shared transport's demux table. Called when a session ends
    /// so stale entries don't accumulate (or spuriously RST future packets for the same peer).
    public func unregister() async {
        await transport.unregister(UTPTransport.UTPConnectionKey(host: remote.host, port: remote.port, connID: recvID))
    }

    private func fail(_ error: any Swift.Error) {
        if let pending = pendingRead {
            pendingRead = nil
            pending.continuation.resume(throwing: error)
        }
    }

    /// True if `a <= b` in 16-bit wrap-around space.
    internal static func seqLE(_ a: UInt16, _ b: UInt16) -> Bool {
        Int16(bitPattern: a &- b) <= 0
    }

    /// True if `a > b` in 16-bit wrap-around space.
    internal static func seqGT(_ a: UInt16, _ b: UInt16) -> Bool {
        Int16(bitPattern: a &- b) > 0
    }
}
