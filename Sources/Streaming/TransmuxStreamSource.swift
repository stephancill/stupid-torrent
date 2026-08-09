import Foundation
import TorrentCore

/// Presents a Matroska file's transmuxed fragmented MP4 as a `TorrentStreamSource`, so the
/// existing resource-loader can serve `.mkv` playback through AVPlayer. Virtual layout:
/// `[init segment][fragment 0][fragment 1]...`, one fragment per MKV cluster.
///
/// Two serving modes:
/// - **Precomputed (complete file)**: when the whole MKV is verified, a structural scan sizes
///   every fragment (headers only, no payload retention), a `sidx` is emitted in the init
///   segment, and seeks jump directly to the target fragment. Exact `contentLength`, byte-range
///   serving, and prioritization.
/// - **Sequential (streaming)**: fragments are generated on demand from the verified MKV cursor;
///   seeks land within already-generated fragments and beyond the frontier follow the
///   "seek waits, doesn't fail" contract. No sidx (future fragments are unknown).
public actor TransmuxStreamSource: TorrentStreamSource {
    private let realSource: any TorrentStreamSource
    private let fileIndex: Int
    /// Extra headroom over the MKV size reported as the virtual content length in streaming
    /// mode. Kept small so AVPlayer's buffering/seek heuristics aren't inflated; the loader
    /// finishes at source EOF regardless.
    private let margin: Int

    private var head: Head?
    /// Real MKV length, fetched (blocking) during head parse.
    private var mkvLength: Int = 0

    // Sequential (streaming) mode state.
    private var fragments: [Fragment] = []
    private var mkvCursor: Int = 0

    // Precomputed (complete file) mode state.
    private var layout: [FragmentPlan]?
    /// Bounded cache of generated fragment bytes (evicts the oldest on insert).
    private var cache: [Int: Data] = [:]

    private struct Head {
        let info: MatroskaInfo
        let remuxer: MKVRemuxer
        var initSegment: Data
    }

    private struct Fragment: Sendable {
        let virtualOffset: Int
        let mkvStart: Int
        let mkvEnd: Int
        let bytes: Data
    }

    private struct FragmentPlan: Sendable {
        let virtualOffset: Int
        let size: Int
        let mkvStart: Int
        let mkvEnd: Int
        let durationTicks: Int64
    }

    public init(realSource: any TorrentStreamSource, fileIndex: Int) {
        self.realSource = realSource
        self.fileIndex = fileIndex
        // Boxes add a few percent over the MKV; cover it without inflating the length much.
        self.margin = 128 * 1024
    }

    // MARK: - TorrentStreamSource

    public func fileLength(fileIndex: Int) async -> Int {
        _ = await ensureHead(blocking: true)
        if let layout {
            return (head?.initSegment.count ?? 0) + layout.reduce(0) { $0 + $1.size }
        }
        return mkvLength > 0 ? mkvLength + margin : margin
    }

    public func availability(fileIndex: Int, offset: Int) async -> Int {
        guard let head = await ensureHead(blocking: false) else { return 0 }
        if offset < head.initSegment.count {
            return head.initSegment.count - offset
        }
        if let layout {
            // Complete file: every fragment is generatable, so the run extends to EOF.
            guard plan(containing: offset) != nil else { return 0 }
            return (head.initSegment.count + layout.reduce(0) { $0 + $1.size }) - offset
        }
        // Sequential mode: generate what's verifiable.
        var pos = offset
        var run = 0
        while true {
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
        if layout != nil {
            guard let plan = plan(containing: offset), let bytes = await generateFragment(plan) else { return nil }
            let local = offset - plan.virtualOffset
            let end = min(local + length, bytes.count)
            return bytes.subdata(in: local..<end)
        }
        guard await ensureFragment(atVirtual: offset, blocking: false) else { return nil }
        guard let fragment = fragment(containing: offset) else { return nil }
        let local = offset - fragment.virtualOffset
        let end = min(local + length, fragment.bytes.count)
        return fragment.bytes.subdata(in: local..<end)
    }

    public func prioritize(fileIndex: Int, range: Range<Int>) async {
        guard let head = await ensureHead(blocking: false) else { return }
        let initSize = head.initSegment.count
        let mkvStart: Int
        if let plan = plan(containing: range.lowerBound) {
            mkvStart = plan.mkvStart + (range.lowerBound - plan.virtualOffset)
        } else if range.lowerBound >= initSize {
            // Beyond the generated layout: jump to the estimated MKV position so a far seek
            // target downloads ahead of the sequential frontier (virtual ≈ MKV after the init).
            let estimate = (head.info.firstClusterOffset ?? 0) + (range.lowerBound - initSize)
            mkvStart = max(0, min(estimate, mkvLength))
        } else {
            mkvStart = mkvCursor
        }
        let end = min(max(mkvStart, mkvCursor) + max(range.count, 2 * 1024 * 1024), mkvLength)
        await realSource.prioritize(fileIndex: fileIndex, range: mkvStart..<end)
    }

    public func reachesEOF(fileIndex: Int, offset: Int) async -> Bool {
        _ = await ensureHead(blocking: false)
        if let layout {
            let virtualEnd = (head?.initSegment.count ?? 0) + layout.reduce(0) { $0 + $1.size }
            return offset >= virtualEnd
        }
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
                        await maybePrecomputeLayout()
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

    /// If the whole MKV is verified, scan its structure to build the exact fragment layout and a
    /// `sidx` in the init segment (precise seeks + exact content length for complete files).
    private func maybePrecomputeLayout() async {
        guard let head, layout == nil else { return }
        guard await realSource.availability(fileIndex: fileIndex, offset: 0) >= mkvLength else { return }
        let scans = await buildLayout(head: head)
        guard let scans, !scans.isEmpty else { return }

        // Build the sidx (its size depends only on the reference list), then compute fragment
        // virtual offsets against the final init segment (ftyp + moov + sidx).
        let references = scans.map { MKVRemuxer.SidxReference(size: $0.size, durationTicks: $0.durationTicks) }
        let finalInit = head.remuxer.initSegment(withSidx: references)
        var plans: [FragmentPlan] = []
        var virtualOffset = finalInit.count
        for scan in scans {
            plans.append(FragmentPlan(
                virtualOffset: virtualOffset,
                size: scan.size,
                mkvStart: scan.mkvStart,
                mkvEnd: scan.mkvEnd,
                durationTicks: scan.durationTicks
            ))
            virtualOffset += scan.size
        }
        self.head?.initSegment = finalInit
        self.layout = plans
    }

    private struct LayoutScan {
        let size: Int
        let durationTicks: Int64
        let mkvStart: Int
        let mkvEnd: Int
    }

    private func buildLayout(head: Head) async -> [LayoutScan]? {
        var scans: [LayoutScan] = []
        var offset = head.info.firstClusterOffset ?? 0
        // MKV ticks → sidx timescale (1000): 1:1 for the standard 1 ms timestamp scale.
        let sidxFactor = Double(1000) * Double(head.info.timestampScaleNs) / 1e9
        while offset < mkvLength {
            let length = min(4 * 1024 * 1024, mkvLength - offset)
            guard let data = await realSource.read(fileIndex: fileIndex, offset: offset, length: length) else { return nil }
            guard let range = try? MatroskaParser.readClusterRange(bytes: data, offset: 0) else { break }
            guard range.elementEnd > 0, range.elementEnd <= data.count else { break }
            guard let clusterLayout = try? MatroskaParser.scanClusterLayout(bytes: range.bytes) else { break }
            let duration = MKVRemuxer.fragmentDuration(clusterLayout, info: head.info)
            scans.append(LayoutScan(
                size: MKVRemuxer.fragmentSize(clusterLayout),
                durationTicks: Int64(Double(duration) * sidxFactor),
                mkvStart: offset,
                mkvEnd: offset + range.elementEnd
            ))
            offset += range.elementEnd
        }
        return scans
    }

    // MARK: - Fragment generation

    /// Generates (and caches) a fragment's bytes for a precomputed layout plan.
    private func generateFragment(_ plan: FragmentPlan) async -> Data? {
        if let cached = cache[plan.virtualOffset] { return cached }
        guard let head else { return nil }
        guard let data = await realSource.read(fileIndex: fileIndex, offset: plan.mkvStart, length: plan.mkvEnd - plan.mkvStart) else { return nil }
        guard let cluster = try? MatroskaParser.parseCluster(bytes: data, segmentDataStart: 0),
              let bytes = try? head.remuxer.consume(cluster) else { return nil }
        if cache.count >= 64, let oldest = cache.keys.min() {
            cache.removeValue(forKey: oldest)
        }
        cache[plan.virtualOffset] = bytes
        return bytes
    }

    private func plan(containing offset: Int) -> FragmentPlan? {
        guard let layout else { return nil }
        var lo = 0
        var hi = layout.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let plan = layout[mid]
            if offset < plan.virtualOffset {
                hi = mid - 1
            } else if offset >= plan.virtualOffset + plan.size {
                lo = mid + 1
            } else {
                return plan
            }
        }
        return nil
    }

    // MARK: - Sequential (streaming) mode

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
                mkvCursor = mkvLength
                return true
            }
            // The cluster might extend beyond the window; grow if more bytes are verified.
            if range.elementEnd > data.count {
                if readSize >= windowCap || readSize >= available {
                    return false
                }
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
