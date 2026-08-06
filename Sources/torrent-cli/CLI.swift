import Foundation
import CoreMedia
import AVFoundation
import TorrentCore
import Streaming

@main
struct TorrentCLI {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            return
        }
        switch args[1] {
        case "add":
            await add(Array(args.dropFirst(2)))
        case "verify":
            await verify(Array(args.dropFirst(2)))
        case "tracker":
            await tracker(Array(args.dropFirst(2)))
        case "stream-test":
            await streamTest(Array(args.dropFirst(2)))
        case "stream-play":
            await streamPlay(Array(args.dropFirst(2)))
        default:
            printUsage()
        }
    }

    static func printUsage() {
        print("""
        torrent-cli v\(TorrentCore.version)
        usage:
          torrent-cli add <file.torrent|magnet:...> [--dir <dir>] [--stop-at <bytes>] [--peer host:port] [--verbose]
          torrent-cli verify <file.torrent> [--dir <dir>]
          torrent-cli tracker <announce-url> --info-hash <hex40> [--verbose]
          torrent-cli stream-test <file.torrent> [--dir <dir>] [--file <index>] [--seed-until <bytes>] [--peer host:port]
        """)
    }

    static func add(_ args: [String]) async {
        guard let path = args.first else {
            print("usage: torrent-cli add <file.torrent> [--dir <dir>] [--stop-at <bytes>]")
            return
        }
        var dir = FileManager.default.currentDirectoryPath + "/downloads"
        var stopAt: Int64?
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--dir":
                if index + 1 < args.count { dir = args[index + 1]; index += 2 } else { index += 1 }
            case "--stop-at":
                if index + 1 < args.count { stopAt = Int64(args[index + 1]); index += 2 } else { index += 1 }
            case "--verbose":
                TorrentLog.verbose = true
                index += 1
            default:
                index += 1
            }
        }
        var injectedPeer: PeerAddress?
        if let peerIdx = args.firstIndex(of: "--peer"), peerIdx + 1 < args.count {
            let parts = args[peerIdx + 1].split(separator: ":")
            if parts.count == 2, let port = UInt16(parts[1]) {
                injectedPeer = PeerAddress(host: String(parts[0]), port: port)
            }
        }
        do {
            let metainfo: Metainfo
            if path.lowercased().hasPrefix("magnet:") {
                let magnet = try MagnetLinkParser.parse(path)
                print("Fetching metadata for \(magnet.displayName ?? magnet.infoHash.hexString)...")
                metainfo = try await MagnetBootstrapper.metainfo(from: magnet, injectedPeer: injectedPeer)
            } else {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                metainfo = try Metainfo(data: data)
            }
            print("Adding \(metainfo.name)")
            print("  hash:  \(metainfo.infoHash.hexString)")
            print("  size:  \(metainfo.totalLength) bytes, \(metainfo.pieceCount) pieces")
            if let stopAt { print("  stopping after \(stopAt) bytes") }

            let dirURL = URL(fileURLWithPath: dir)
            let torrent = Torrent(directory: dirURL, metainfo: metainfo, stopAfterBytes: stopAt)
            if let injectedPeer {
                await torrent.addPeer(host: injectedPeer.host, port: injectedPeer.port)
            }
            let printer = Task {
                for await status in await torrent.statusBroadcast.subscribe() {
                    let bar = progressBar(status.progress)
                    print("\r\(bar) \(Int(status.progress * 100))%  ↓\(fmtRate(status.downloadRate))  peers \(status.peers) seeds \(status.seeds)  \(status.verifiedCount)/\(status.pieceCount) pieces", terminator: "")
                    fflush(stdout)
                }
            }
            await torrent.run()
            printer.cancel()
            print()

            let result = try await PieceVerifier.verify(metainfo: metainfo, directory: dirURL)
            print("Verify: ok=\(result.ok.count) bad=\(result.bad.count) missing=\(result.missing.count)")
            if !result.bad.isEmpty {
                print("  bad pieces: \(result.bad.prefix(20))")
            }
            if !result.missing.isEmpty {
                print("  missing pieces: \(result.missing.prefix(20))")
            }
        } catch {
            print("error: \(error)")
        }
    }

    static func verify(_ args: [String]) async {
        guard let path = args.first else {
            print("usage: torrent-cli verify <file.torrent> [--dir <dir>]")
            return
        }
        var dir = FileManager.default.currentDirectoryPath + "/downloads"
        var index = 1
        while index < args.count {
            if args[index] == "--dir", index + 1 < args.count {
                dir = args[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let metainfo = try Metainfo(data: data)
            let result = try await PieceVerifier.verify(metainfo: metainfo, directory: URL(fileURLWithPath: dir))
            print("\(metainfo.name): ok=\(result.ok.count) bad=\(result.bad.count) missing=\(result.missing.count) of \(metainfo.pieceCount)")
            if !result.bad.isEmpty { print("  bad: \(result.bad)") }
            if !result.missing.isEmpty { print("  missing (first 50): \(result.missing.prefix(50))") }
        } catch {
            print("error: \(error)")
        }
    }

    static func streamTest(_ args: [String]) async {
        guard let path = args.first else {
            print("usage: torrent-cli stream-test <file.torrent> [--dir <dir>] [--file <index>] [--seed-until <bytes>] [--peer host:port]")
            return
        }
        var dir = FileManager.default.currentDirectoryPath + "/downloads"
        var fileIndex: Int?
        var seedUntil: Int64 = 2 * 1024 * 1024
        var injectedPeer: PeerAddress?
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--dir":
                if index + 1 < args.count { dir = args[index + 1]; index += 2 } else { index += 1 }
            case "--file":
                if index + 1 < args.count { fileIndex = Int(args[index + 1]); index += 2 } else { index += 1 }
            case "--seed-until":
                if index + 1 < args.count { seedUntil = Int64(args[index + 1]) ?? seedUntil; index += 2 } else { index += 1 }
            case "--peer":
                if index + 1 < args.count {
                    let parts = args[index + 1].split(separator: ":")
                    if parts.count == 2, let port = UInt16(parts[1]) {
                        injectedPeer = PeerAddress(host: String(parts[0]), port: port)
                    }
                    index += 2
                } else { index += 1 }
            case "--verbose":
                TorrentLog.verbose = true
                index += 1
            default:
                index += 1
            }
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let metainfo = try Metainfo(data: data)
            let dirURL = URL(fileURLWithPath: dir)
            let index = fileIndex ?? metainfo.files.indices.first {
                Torrent.contentType(forFileNamed: metainfo.files[$0].name) != nil
            } ?? 0
            let mediaName = metainfo.files[index].name
            print("Streaming file \(index): \(mediaName) (\(metainfo.files[index].length) bytes)")

            let partial = Torrent(directory: dirURL, metainfo: metainfo, stopAfterBytes: seedUntil)
            if let injectedPeer {
                await partial.addPeer(host: injectedPeer.host, port: injectedPeer.port)
            }
            print("  -> starting partial download...")
            await partial.run()
            print("Partial download done: \(await partial.verifiedCount)/\(metainfo.pieceCount) pieces verified")

            print("  -> starting stream torrent...")
            let stream = Torrent(directory: dirURL, metainfo: metainfo)
            if let injectedPeer {
                await stream.addPeer(host: injectedPeer.host, port: injectedPeer.port)
            }
            let streamTask = Task { await stream.run() }

            print("  -> loading asset...")
            let session = TorrentStreamSession(torrent: stream, fileIndex: index)
            do {
                let duration = try await withThrowingTaskGroup(of: CMTime.self) { group in
                    group.addTask { try await session.asset.load(.duration) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(30))
                        throw NSError(domain: "stream-test", code: -1, userInfo: [NSLocalizedDescriptionKey: "asset load timed out"])
                    }
                    guard let result = try await group.next() else {
                        throw NSError(domain: "stream-test", code: -1, userInfo: [NSLocalizedDescriptionKey: "no result"])
                    }
                    group.cancelAll()
                    return result
                }
                let seconds = CMTimeGetSeconds(duration)
                let playable = (try? await session.asset.load(.isPlayable)) ?? false
                print("ASSET: duration=\(seconds)s playable=\(playable)")
                if seconds > 0 {
                    print("STREAM OK: media loads and is playable before 100% download")
                } else {
                    print("STREAM FAIL: duration is 0")
                }
            } catch {
                print("asset load error: \(error)")
            }
            streamTask.cancel()
            await stream.stop()
        } catch {
            print("error: \(error)")
        }
    }

    static func streamPlay(_ args: [String]) async {
        guard let path = args.first else {
            print("usage: torrent-cli stream-play <file.torrent> [--dir <dir>] [--file <index>] [--seed-until <bytes>] [--peer host:port] [--seconds <n>]")
            return
        }
        var dir = FileManager.default.currentDirectoryPath + "/downloads"
        var fileIndex: Int?
        var seedUntil: Int64 = 3 * 1024 * 1024
        var seconds = 30
        var injectedPeer: PeerAddress?
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--dir":
                if index + 1 < args.count { dir = args[index + 1]; index += 2 } else { index += 1 }
            case "--file":
                if index + 1 < args.count { fileIndex = Int(args[index + 1]); index += 2 } else { index += 1 }
            case "--seed-until":
                if index + 1 < args.count { seedUntil = Int64(args[index + 1]) ?? seedUntil; index += 2 } else { index += 1 }
            case "--seconds":
                if index + 1 < args.count { seconds = Int(args[index + 1]) ?? seconds; index += 2 } else { index += 1 }
            case "--peer":
                if index + 1 < args.count {
                    let parts = args[index + 1].split(separator: ":")
                    if parts.count == 2, let port = UInt16(parts[1]) {
                        injectedPeer = PeerAddress(host: String(parts[0]), port: port)
                    }
                    index += 2
                } else { index += 1 }
            default:
                index += 1
            }
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let metainfo = try Metainfo(data: data)
            let dirURL = URL(fileURLWithPath: dir)
            let index = fileIndex ?? metainfo.files.indices.first {
                Torrent.contentType(forFileNamed: metainfo.files[$0].name) != nil
            } ?? 0

            let partial = Torrent(directory: dirURL, metainfo: metainfo, stopAfterBytes: seedUntil)
            if let injectedPeer {
                await partial.addPeer(host: injectedPeer.host, port: injectedPeer.port)
            }
            await partial.run()
            print("Partial: \(await partial.verifiedCount)/\(metainfo.pieceCount) verified")

            let stream = Torrent(directory: dirURL, metainfo: metainfo)
            if let injectedPeer {
                await stream.addPeer(host: injectedPeer.host, port: injectedPeer.port)
            }
            let streamTask = Task { await stream.run() }

            let session = TorrentStreamSession(torrent: stream, fileIndex: index)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: session.asset))
            player.play()

            var maxTime: Double = 0
            for tick in 1...seconds {
                try? await Task.sleep(for: .seconds(1))
                let time = CMTimeGetSeconds(player.currentTime())
                maxTime = max(maxTime, time)
                let verified = await stream.verifiedCount
                print("t=\(tick)s playhead=\(String(format: "%.1f", time))s verified=\(verified)/\(metainfo.pieceCount)")
                if time > 0 && time >= maxTime && tick > 5 && verified >= metainfo.pieceCount {
                    break
                }
            }
            let item = player.currentItem
            let duration = item?.duration.isNumeric == true ? CMTimeGetSeconds(item!.duration) : -1
            print("MAX PLAYHEAD: \(String(format: "%.1f", maxTime))s  (duration \(String(format: "%.1f", duration))s)")
            print(maxTime > 5 ? "STREAM-PLAY OK: played past 5s" : "STREAM-PLAY FAIL: stalled early")
            player.pause()
            streamTask.cancel()
            await stream.stop()
        } catch {
            print("error: \(error)")
        }
    }

    static func tracker(_ args: [String]) async {
        guard let urlString = args.first, let url = URL(string: urlString) else {
            print("usage: torrent-cli tracker <announce-url> --info-hash <hex40> [--verbose]")
            return
        }
        var infoHash = Data()
        for arg in args.dropFirst() {
            if arg == "--info-hash", let idx = args.firstIndex(of: arg), idx + 1 < args.count,
               let data = hexData(args[idx + 1]) {
                infoHash = data
            }
            if arg == "--verbose" { TorrentLog.verbose = true }
        }
        guard infoHash.count == 20 else {
            print("error: --info-hash must be 40 hex chars")
            return
        }
        do {
            let client = try TrackerClientFactory.makeClient(for: url)
            let request = AnnounceRequest(
                infoHash: infoHash,
                peerID: PeerID.generate(),
                port: 6881,
                left: 0,
                event: .started,
                numWant: 20
            )
            let response = try await client.announce(request)
            print("interval: \(response.interval)")
            print("seeders: \(response.seeders ?? -1) leechers: \(response.leechers ?? -1)")
            print("peers (\(response.peers.count)): \(response.peers.map { "\($0.host):\($0.port)" }.joined(separator: ", "))")
            if let failure = response.failureReason {
                print("failure: \(failure)")
            }
        } catch {
            print("error: \(error)")
        }
    }

    static func hexData(_ string: String) -> Data? {
        guard string.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    static func progressBar(_ progress: Double) -> String {
        let width = 40
        let filled = Int(progress * Double(width))
        let bar = String(repeating: "=", count: filled) + String(repeating: "-", count: width - filled)
        return "[\(bar)]"
    }

    static func fmtRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
