import Foundation
import TorrentCore

/// Presents a Matroska file's transmuxed fragmented MP4 as a `TorrentStreamSource`, so the
/// existing resource-loader can serve `.mkv` playback through AVPlayer. Virtual layout:
/// `[init segment][fragment 0][fragment 1]...`, one fragment per MKV cluster. Fragments are
/// generated on demand from the real (verified) MKV bytes via `MKVRemuxer`; the virtual offset
/// of each fragment depends on the sizes of all prior fragments, so generation is sequential
/// from the current MKV cursor. Seeks land precisely within already-generated fragments;
/// seeks beyond the downloaded frontier fall back to the sequential arrival (the same
/// "seek waits, doesn't fail" contract as the loopback HTTP server).
public actor TransmuxStreamSource: TorrentStreamSource {
    private let realSource: any TorrentStreamSource
    private let fileIndex: Int
    /// Extra headroom over the MKV size reported as the virtual content length, so the whole
    /// virtual file (init + fragment box overhead) is always covered. Kept small so AVPlayer's
    /// buffering/seek heuristics aren't inflated; the loader finishes at source EOF regardless.
    private let margin: Int

    private var head: Head?
    private var fragments: [Fragment] = []
    /// Next MKV byte offset to scan for a cluster.
    private var mkvCursor: Int = 0
    /// Real MKV length, fetched (blocking) during head parse.
    private var mkvLength: Int = 0

    private struct Head {
        let info: MatroskaInfo
        let remuxer: MKVRemuxer
        let initSegment: Data
    }

    private struct Fragment: Sendable {
        let virtualOffset: Int
        let mkvStart: Int
        let mkvEnd: Int
        let bytes: Data
    }

    public init(realSource: any TorrentStreamSource, fileIndex: Int) {
        self.realSource = realSource
        self.fileIndex = fileIndex
        // Boxes add a few percent over the MKV; cover it without inflating the length much.
        self.margin = 128 * 1024
    }

    // MARK: - TorrentStreamSource

    public func fileLength(fileIndex: Int) async -> Int {
        // The virtual length needs the parsed head (it determines the real MKV length and the
        // init segment). Ensure it so the loader reports a correct contentLength instead of the
        // bare margin.
        _ = await ensureHead(blocking: true)
        return mkvLength > 0 ? mkvLength + margin : margin
    }

    public func availability(fileIndex: Int, offset: Int) async -> Int {
        guard let head = await ensureHead(blocking: false) else { return 0 }
        var pos = offset
        if pos < head.initSegment.count {
            return head.initSegment.count - pos
        }
        var run = 0
        while true {
            // Generate the fragment covering `pos` if its MKV bytes are verified (best-effort).
            guard await ensureFragment(atVirtual: pos, blocking: false) else { break }
            guard let fragment = fragment(containing: pos) else { break }
            run += fragment.bytes.count - (pos - fragment.virtualOffset)
            pos = fragment.virtualOffset + fragment.bytes.count
        }
        return run
    }

    public func read(fileIndex: Int, offset: Int, length: Int) async -> Data? {
        guard let head = await ensureHead(blocking: false) else { return nil }
        if offset < head.initSegment.count {
            let end = min(offset + length, head.initSegment.count)
            return head.initSegment.subdata(in: offset..<end)
        }
        guard await ensureFragment(atVirtual: offset, blocking: false) else { return nil }
        guard let fragment = fragment(containing: offset) else { return nil }
        let local = offset - fragment.virtualOffset
        let end = min(local + length, fragment.bytes.count)
        return fragment.bytes.subdata(in: local..<end)
    }

    public func prioritize(fileIndex: Int, range: Range<Int>) async {
        guard let head = await ensureHead(blocking: false) else { return }
        let mkvStart: Int
        if range.lowerBound >= head.initSegment.count, let fragment = fragment(containing: range.lowerBound) {
            mkvStart = fragment.mkvStart + (range.lowerBound - fragment.virtualOffset)
        } else {
            // Not generated yet: prioritize at the sequential frontier (approximate).
            mkvStart = mkvCursor
        }
        let end = min(mkvStart + max(range.count, 2 * 1024 * 1024), mkvLength)
        await realSource.prioritize(fileIndex: fileIndex, range: mkvStart..<end)
    }

    public func reachesEOF(fileIndex: Int, offset: Int) async -> Bool {
        guard let head = await ensureHead(blocking: false) else { return false }
        return mkvCursor >= mkvLength && mkvLength > 0
    }

    // MARK: - Head

    private func ensureHead(blocking: Bool) async -> Head? {
        if let head { return head }
        if mkvLength == 0 {
            mkvLength = await realSource.fileLength(fileIndex: fileIndex)
        }
        guard mkvLength > 0 else { return nil }

        // Parse the head from a growing verified prefix (clamped to the real length).
        var window = min(256 * 1024, mkvLength)
        let cap = min(4 * 1024 * 1024, mkvLength)
        while window <= cap {
            if let data = await realSource.read(fileIndex: fileIndex, offset: 0, length: window) {
                do {
                    let info = try MatroskaParser.parseHead(bytes: data)
                    let remuxer = try MKVRemuxer(info: info)
                    guard remuxer.hasMedia else { return nil }
                    let initSegment = remuxer.initSegment()
                    let realLength = await realSource.fileLength(fileIndex: fileIndex)
                    if head == nil {
                        head = Head(info: info, remuxer: remuxer, initSegment: initSegment)
                        mkvCursor = info.firstClusterOffset ?? 0
                        mkvLength = realLength
                    }
                    return head!
                } catch MatroskaError.truncated {
                    window *= 2
                    continue
                } catch {
                    return nil
                }
            }
            if blocking {
                try? await Task.sleep(for: .milliseconds(200))
            } else {
                return nil
            }
        }
        return nil
    }

    // MARK: - Fragments

    /// Generates fragments sequentially from the MKV cursor until a fragment covering `target`
    /// exists, or the MKV bytes needed aren't verified yet. Non-blocking: returns false when the
    /// next cluster's bytes aren't available.
    private func ensureFragment(atVirtual target: Int, blocking: Bool) async -> Bool {
        while true {
            guard let head else { return false }
            if fragment(containing: target) != nil { return true }
            if mkvCursor >= mkvLength, mkvLength > 0 { return true } // EOF: no more fragments

            let generated = await generateNextFragment(head: head)
            if !generated {
                if blocking {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                return false
            }
        }
    }

    /// Reads and muxes the cluster at the cursor, appending its fragment. Returns false if the
    /// cluster bytes aren't verified yet. Reads are sized to the verified run so a window never
    /// extends past the downloaded frontier.
    private func generateNextFragment(head: Head) async -> Bool {
        let cursor = mkvCursor
        let available = await realSource.availability(fileIndex: fileIndex, offset: cursor)
        guard available > 0 else { return false }
        let windowCap = min(4 * 1024 * 1024, max(mkvLength - cursor, 0))
        var readSize = min(256 * 1024, windowCap, available)
        while readSize > 0 {
            guard let data = await realSource.read(fileIndex: fileIndex, offset: cursor, length: readSize) else {
                return false
            }
            guard let range = try? MatroskaParser.readClusterRange(bytes: data, offset: 0) else {
                // Verified bytes but no cluster at the cursor: the cluster run is exhausted
                // (tail elements like Cues). Consume to EOF so `reachesEOF` reports the end.
                mkvCursor = mkvLength
                return true
            }
            // The cluster might extend beyond the window; grow if more bytes are verified.
            if range.elementEnd > data.count {
                if readSize >= windowCap || readSize >= available { return false }
                readSize = min(readSize * 2, windowCap, available)
                continue
            }
            let clusterBytes = range.bytes
            guard let cluster = try? MatroskaParser.parseCluster(bytes: clusterBytes, segmentDataStart: 0),
                  let fragmentBytes = try? head.remuxer.consume(cluster) else {
                // Unsupported cluster: skip past it so streaming can continue.
                mkvCursor = cursor + range.elementEnd
                return true
            }
            let virtualOffset = head.initSegment.count + fragments.reduce(0) { $0 + $1.bytes.count }
            fragments.append(Fragment(
                virtualOffset: virtualOffset,
                mkvStart: cursor,
                mkvEnd: cursor + range.elementEnd,
                bytes: fragmentBytes
            ))
            mkvCursor = cursor + range.elementEnd
            return true
        }
        return false
    }

    private func fragment(containing offset: Int) -> Fragment? {
        // Fragments are appended in virtual-offset order; scan from the end (usual case: near
        // the tail) since the common access pattern is sequential.
        for fragment in fragments.reversed() {
            if offset >= fragment.virtualOffset, offset < fragment.virtualOffset + fragment.bytes.count {
                return fragment
            }
        }
        return nil
    }
}
