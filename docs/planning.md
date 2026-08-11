# Planning — stupid-torrent-client

## Goal

An xtool iOS app (SwiftPM + SwiftUI) where you paste a **magnet link** or import a **.torrent file**, download files, and **stream media files while they are still downloading**. Foreground-only: iOS suspends apps shortly after they go to the background, so true background torrenting is out of scope.

## Decisions (locked in)

1. **Engine: from scratch, pure Swift.** No libtorrent/C++, no vendored frameworks, no binary targets. Zero build/link risk under xtool's cross SDK, and the streaming model (priority-window piece picking) is native to our own picker. Closely modeled on two MIT references.
2. **Scope v1: full** — magnet links + `.torrent` files, sequential/priority-window download, seeding, per-file selection and priorities, AVPlayer streaming, DHT (BEP 5) peer discovery, MSE/PE protocol encryption (BEP 10), µTP transport (BEP 29). **No web seeds (BEP 19)** — deferred.
3. **Streaming: AVPlayer backed by verified torrent bytes.** Apple containers use `AVAssetResourceLoaderDelegate` over a custom scheme. Cue-indexed Matroska uses a static VOD HLS presentation over a loopback-only HTTP server so one stable `AVPlayerItem` owns the global timeline while independently generated fMP4 cue segments retain local decoder clocks. `UIBackgroundModes: audio` supports background audio streaming.
4. **Validation-first: macOS `torrent-cli`** headless harness gates every engine phase against the live Big Buck Bunny torrent before any iOS UI work.
5. **Concurrency: Swift 6 strict concurrency** with actors; networking over Network.framework `NWConnection`, bridged to `async`/`AsyncStream`. Engine status is fanned out through a `StatusBroadcast` (multi-subscriber, current-value); SwiftUI observes a main-actor `@Observable` `TorrentStore` snapshot.
6. **Hermetic-first testing**: mock HTTP/UDP trackers + a local third-party seeder (webtorrent/aria2c) serving the Big Buck Bunny fixture over loopback give deterministic, offline coverage for PeerWire/Peer/PiecePicker/Storage/Tracker. The live swarm is only the final integration gate.

## Test torrent (primary: Big Buck Bunny)

- Magnet (canonical, with fallback trackers):
  `magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce`
- `.torrent`: `https://webtorrent.io/torrents/big-buck-bunny.torrent` (committed as `Fixtures/big-buck-bunny.torrent` so tests don't depend on the network to fetch it)
- Info hash: `dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c`
- Files (multi-file, pieces span file boundaries):
  - `Big Buck Bunny.mp4` — 276,134,947 B (H.264/AAC, AVPlayer-playable → streaming test)
  - `Big Buck Bunny.en.srt` — 140 B
  - `poster.jpg` — 310,380 B
- Piece length: 262,144 B (256 KiB)
- Trackers: **UDP only** in the original magnet. Probe results (2026-08-06): both UP — `tracker.opentrackr.org:1337` answers both UDP and HTTP announces; `explodie.org:6969` is UDP-only. The canonical magnet above appends two more fallbacks (`open.stealth.si:80`, `tracker.torrent.eu.org:451`); the engine also cycles trackers and retries on announce failure. UDP tracker support must land before the first live download.
- Seed cache: `third-party/seeder-cache/` (gitignored) holds the BBB files so the hermetic seeder can serve them offline. Populated once from the live swarm, then all iteration is offline/deterministic (see "Hermetic testing").

Secondary alternatives: Sintel (`08ada5a7a6183aae1e09d831df6748d566095a10`), Cosmos Laundromat (`c9e15763f722f23e98a29decdfae341b98d53056`).

## References (cloned into `third-party/`, gitignored, for consultation only)

- `webtorrent/webtorrent` (JS, MIT) — module structure + streaming orchestration. Mirror its `wire/tracker/dht/file/torrent` decomposition and its magnet -> metadata -> sequential/priority download flow.
- `anacrolix/torrent` (Go, MIT) — correctness reference for peer-wire edge cases, sparse storage, rarest-first/endgame, tracker behavior, BEP handling.
- Spec source of truth: BEP 3 (metainfo), BEP 9 (ut_metadata), BEP 10 (extensions), BEP 23 (compact peer lists), BEP 5 (DHT), BEP 29 (µTP).

## Hermetic testing (deterministic, offline)

Live-swarm gates are the final check, not the only one. A test-support harness gives deterministic coverage of PeerWire, Peer, PiecePicker, Storage, and trackers.

- `TorrentTestingSupport` (test-only target) provides:
  - **Mock HTTP tracker** — bencoded announce responses (configurable compact `peers`/`peers6` lists, `interval`, `failure reason`); asserts the started/completed/stopped lifecycle and `numwant`.
  - **Mock UDP tracker** — connect/announce protocol over a loopback UDP socket; asserts transaction-id matching, action codes, and retry behavior.
  - **Peer injector** — `Client.addPeer(ip:port:)` connects our engine directly to a specific seeder address without any tracker (fully deterministic path).
  - **Synthetic torrent generator** — small, fully deterministic multi-file torrents (controlled piece length, files spanning piece boundaries) for fast codec/picker/storage tests with no network.
- **Seeder = an existing, battle-tested package, not ours.** The hermetic seeder serves the real BBB fixture over loopback using `webtorrent` (npm, run from the `third-party/webtorrent` reference clone) or, as fallback, `aria2c` (installed at `/opt/homebrew/bin/aria2c`). Using a correct third-party implementation as the peer derisks our wire protocol against real-world behavior without swarm flakiness.
- **Hermetic download gate**: create a Torrent from `Fixtures/big-buck-bunny.torrent`, inject the loopback seeder peer, download to 100% offline, and SHA-1-verify every piece.
- Unit-test gates are explicit per phase (see Phases); hermetic gates run with `swift test` (network only needed for one-time seed-cache population).

## Architecture

```
Package.swift (swift-tools 6.0; platforms: iOS 17 / macOS 14)
├─ product  stupid_torrent_client      (library, the app — the only library product; xtool picks it)
├─ product  torrent-cli                (macOS executable — xtool ignores executables)
├─ target   Bencode                    (pure Swift)
├─ target   TorrentCore                (pure Swift; the engine, dependency-free)
├─ target   Streaming                  (AVFoundation/AVKit; player feeding)
├─ target   StupidTorrentClientApp     (SwiftUI @main)
└─ target   torrent-cli                (Swift, macOS harness)
```

### TorrentCore modules (mirroring webtorrent)

| Module | Responsibility |
|---|---|
| `Metainfo` | `.torrent` + magnet parsing; info dict -> piece hashes, piece length, file list; piece->file mapping (pieces span file boundaries) |
| `PeerID` | 20-byte peer id, `-ST0001-` + random |
| `PeerWire` | length-prefixed message codec; IDs 0-9 + extended (20); keepalive; block encode/decode; BEP 10 extended handshake; BEP 9 ut_metadata (16 KiB chunk assembly, SHA-1 against info hash) |
| `Peer` | `NWConnection` state machine: TCP connect, handshake (extension bit), choke/unchoke/interested, request pipeline (16 KiB blocks, ~16-32 outstanding), keepalive timer, stall detection |
| `UTP`/`UTPConnection`/`UTPTransport` | µTP (BEP 29): wire codec (20-byte header, extensions), per-connection seq/ack + retransmit + reorder buffering, shared UDP demux socket + retransmit ticker. Modeled on libutp; peers connect over µTP first with TCP fallback |
| `Tracker` | HTTP(S) announce via `URLSession` (bencoded response, `compact=1`, `peers`/`peers6`, interval/numwant, started/completed/stopped); UDP announce via `NWConnection` (.udp, connect -> announce, spec retries). Aggregates peer lists |
| `PiecePicker` | sequential mode + priority window (primary); jump-to-requested-range for streaming; optional endgame; per-file priority honoring piece-spanning |
| `Storage` | sparse multi-file writes via `pwrite`; verified-piece bitfield; SHA-1 via `CryptoKit.Insecure.SHA1`; resume sidecars; disk-space guard (check `volumeAvailableCapacityForImportantUsage` before allocating; on ENOSPC fail loudly — pause the torrent and surface an error) |
| `Torrent` (actor) | orchestrates magnet -> metadata -> download -> seed; publishes status snapshots via `StatusBroadcast` |
| `StatusBroadcast` | concurrency-safe, multi-subscriber current-value stream (actor; replays current value on subscribe; supports N subscribers) |
| `Client` | session: peer connection pool, reconnects, tracker cycling, rate/peer limits |

### Streaming design

`Streaming` is the only target besides the app that uses Apple frameworks (AVFoundation/AVKit: `AVAssetResourceLoaderDelegate`, `AVPlayer`); `TorrentCore`/`Bencode` stay dependency-free.

1. User taps play on a media file -> `StreamController` selects that file, sets its pieces high priority, others paused.
2. Apple containers use `AVURLAsset(stream://...)` + `TorrentResourceLoader`. The loader answers `contentInformationRequest` (type from `ftyp`/extension, total length, `isByteRangeAccessSupported = true`) and holds `dataRequest`s until their bytes are verified, feeding from `Storage`.
3. Picker drives playback: sequential window around current position + moov-tail jump (when the loader sees a non-zero offset request — AVPlayer probing a tail `moov` atom on non-faststart MP4 — temporarily prioritize that region, then resume sequential).
4. Playback begins after the loader supplies `moov` + leading frames.
5. Cue-indexed MKV/MKA stream through **AVPlayer** via an in-house Matroska → fragmented-MP4 transmuxer (`Streaming`: EBML parse → static full-duration VOD HLS playlist + independently generated local-timeline fMP4 cue segments). `EXT-X-DISCONTINUITY` maps each local decoder timeline into one stable HLS movie timeline, preserving native AVKit controls and PiP without replacing the player item. A loopback-only HTTP server exposes the playlist/init/segments because `AVAssetResourceLoaderDelegate` is not a supported HLS media transport. The file row validates and prioritizes the Cues index asynchronously; a partial MKV's play button stays disabled until a usable index is available. Missing/invalid Cues disable streaming until the file completes, after which the exact complete-file fMP4 path can play it. There is no app-owned MKV player UI. Covers H.264/HEVC video and AAC/E-AC-3/AC-3/ALAC audio; embedded subtitles and Opus/Vorbis/FLAC/DTS are dropped (see `docs/mkv-avplayer-transmuxer.md`). Other formats (webm/avi/AV1-in-MKV) remain unplayable.

### Persistence

- `Documents/torrents/` — original `.torrent` files + a magnet link list (restore set)
- `Documents/downloads/` — data files (exposed via Files app)
- Per-torrent verified-bitfield sidecar for fast resume (re-verify only unverified pieces on launch)

## iOS config (custom `Info.plist` via `xtool.yml infoPath`)

- `UIBackgroundModes: ["audio"]`
- `CFBundleURLTypes`: `magnet` URL scheme
- `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
- `NSAppTransportSecurity` -> `NSAllowsArbitraryLoads: true` (ATS applies to our `URLSession` HTTP-tracker calls; raw peer sockets are unaffected)
- `NSLocalNetworkUsageDescription` (future DHT/inbound listen)

## Phases

1. **Scaffold** — Package.swift (products/targets), xtool.yml, Info.plist, gitignore, reference clones, docs. Gate: `swift build` and `swift build --product torrent-cli` succeed.
2. **Bencode + Metainfo** — with unit tests; parse the BBB `.torrent` fixture. Gate: tests pass.
3. **PeerWire + Tracker (HTTP + UDP) + Storage (sequential)** — wire codec, announce clients, sequential picker, sparse storage. Unit tests: PeerWire message round-trip + malformed/truncated framing; HTTP announce request + bencoded response parse (compact peers/peers6, interval, failure reason); UDP connect/announce encode-decode with transaction-id matching; synthetic-torrent sequential download via the loopback seeder. Gate: `swift test` green, then live BBB `.torrent` to 100% with `torrent-cli verify` showing every piece `ok`.
4. **Multi-file storage + resume** — piece->file offset layout (files spanning pieces) unit tests against the fixture; bitfield persistence round-trip; kill + relaunch resumes without full recheck. Gate: sizes match + fast resume (hermetic, then live).
5. **ut_metadata + magnet flow** — BEP 10/9. Unit tests: extended-handshake + ut_metadata message build/parse; 16 KiB chunking/assembly + SHA-1 against the fixture info dict. Gate: `swift test` green, then `torrent-cli add <BBB magnet>` (hermetic seeder, then live) downloads fully.
6. **Streaming** — resource loader, priority window, moov-tail; deterministic streaming test from the partial seed cache, then macOS-sim and live. Gate: video plays before 100% download.
7. **SwiftUI app** — list/detail/add (magnet paste + `fileImporter` .torrent)/player, file selection, persistence. Gate: full flow on device.
8. **Polish** — seeding, pause/resume, app icon (xtool-app-icon skill), implementation notes, README. Optional later: DHT.

## `torrent-cli` commands

- `torrent-cli add <magnet|path>` — add and download (flags: `--stop-at <bytes>`, `--dir <savePath>`)
- `torrent-cli status [<hash>]` — live status (progress, rates, seeds/peers, state)
- `torrent-cli verify <hash>` — recompute SHA-1 per piece from `Storage`, compare to the torrent's `pieces`; print per-piece `ok`/`bad`/`missing`. **The direct piece-correctness gate.**

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Swift 6 concurrency friction (actors + `NWConnection` callbacks, status fan-out) | Bridge callbacks to `async` early; `StatusBroadcast` for multi-subscriber current-value; validate on macOS in Phase 3 |
| Magnet dependency chain (magnet requires peer-wire + BEP 10/9 all working) | Phases build bottom-up, each gated by unit + hermetic tests |
| Tracker/peer long tail | Follow anacrolix/webtorrent behavior; hermetic coverage via mock trackers + third-party seeder (webtorrent/aria2c); live swarm as final gate; fail loudly with clear logs |
| iOS suspension in background | Foreground-only by design + `audio` background mode |
| mkv/AV1 not playable by AVPlayer | MKV/MKA streamed via the in-house Matroska→fMP4 transmuxer (AVPlayer-native, no framework; see `docs/mkv-avplayer-transmuxer.md`); AV1-in-MKV / webm / avi remain unplayable; embedded subs + Opus/Vorbis/FLAC/DTS dropped |
| BBB is UDP-tracker-only | UDP tracker lands in Phase 3 (before first live download); both BBB trackers probed UP on 2026-08-06 (opentrackr HTTP+UDP, explodie UDP-only), plus fallback trackers in the magnet |
| Torrent can exceed free disk space | Storage disk-space guard (`volumeAvailableCapacityForImportantUsage`); fail loudly (pause + surface error) on ENOSPC |

## Out of scope (v1)

Web seeds (BEP 19), background downloads, IPv6 peer support (decode-ignore). Note: MSE/PE and µTP (BEP 29) are now implemented; outbound connections try µTP first (reaching µTP-only peers, e.g. WebTorrent's) and fall back to TCP, and the shared UDP socket also accepts inbound µTP on the announced port. WebRTC (for WebTorrent's browser-only peers) remains out of scope.
