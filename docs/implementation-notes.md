# Implementation notes — stupid-torrent-client

Running implementation log. Update **before every commit** with a concise entry describing what changed and why. Reference the relevant phase in `docs/planning.md`.

## 2026-08-06 — Project docs scaffold (Phase 1 prep)

- Created `AGENTS.md` with tech stack, required rules (read planning/implementation notes before changes, update notes before commit, verify with Big Buck Bunny via `torrent-cli`), coding style, and commands.
- Created `docs/planning.md` capturing all locked-in decisions:
  - From-scratch pure-Swift BitTorrent engine (no libtorrent), modeled on webtorrent + anacrolix/torrent.
  - Full scope v1 (magnet + `.torrent`, sequential/priority streaming, seeding, per-file selection); DHT/µTP/encryption/webseeds deferred.
  - Big Buck Bunny (info hash `dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c`) as the live verification torrent; UDP-tracker-only, so UDP tracker support is scheduled into Phase 3.
  - macOS `torrent-cli` validation-first workflow; 8 implementation phases with gates.
- Created this `docs/implementation-notes.md`.
- Next: Phase 1 scaffold (Package.swift with `Bencode`/`TorrentCore`/`Streaming`/`StupidTorrentClientApp`/`torrent-cli` targets, xtool.yml, custom Info.plist, gitignore, clone references into `third-party/`).

## 2026-08-06 — Plan revision: hermetic testing, unit-test gates, tracker reliability, status fan-out

Addressed review feedback in `docs/planning.md` and `AGENTS.md`:

1. **Hermetic testing added** (new section): `TorrentTestingSupport` test target with mock HTTP tracker, mock UDP tracker, peer injector (`Client.addPeer`), and a synthetic torrent generator. The seeding fixture is an existing battle-tested package (`webtorrent` npm from the `third-party/` clone, `aria2c` fallback) serving the BBB fixture over loopback — so our wire protocol is validated against a correct implementation deterministically, not the flaky live swarm. Live swarm stays as the final integration gate. BBB seed cache (`third-party/seeder-cache/`, gitignored) enables offline iteration after one-time population.
2. **Unit-test surface strengthened**: phases 3-5 now carry explicit fixture-based test gates (PeerWire codec round-trip + malformed framing; HTTP/UDP tracker announce encode/decode + response parsing; piece->file offset layout; bitfield persistence; ut_metadata chunking/assembly + SHA-1).
3. **Tracker reliability verified**: probed both BBB UDP trackers live on 2026-08-06 — `tracker.opentrackr.org:1337` (HTTP+UDP) and `explodie.org:6969` (UDP) both UP. Canonical magnet updated with fallback trackers (`open.stealth.si:80`, `tracker.torrent.eu.org:451`); engine cycles/retries trackers.
4. **Status fan-out designed**: `StatusBroadcast` actor (multi-subscriber, current-value, replay-on-subscribe) replaces raw single-subscriber `AsyncStream`; SwiftUI observes a main-actor `@Observable` `TorrentStore` snapshot.
5. **Wording + disk space**: `Streaming`/app may use AVFoundation/AVKit (only `TorrentCore`/`Bencode` are dependency-free) — fixed in AGENTS.md and planning.md. Storage now includes a disk-space guard (fail loudly on ENOSPC).
6. **Confirmed**: `-ST0001-` peer id convention and IPv6 decode-ignore scoping are fine as-is.

Next: Phase 1 scaffold (Package.swift with `Bencode`/`TorrentCore`/`Streaming`/`StupidTorrentClientApp`/`torrent-cli` targets + `TorrentTestingSupport`, xtool.yml, custom Info.plist, gitignore, clone references into `third-party/`, commit the BBB `.torrent` fixture).

## 2026-08-06 — Phase 1 scaffold + Phase 2 (bencode / metainfo / magnet)

### Phase 1 — Scaffold (done)
- Generated the project with `xtool new stupid-torrent-client` (temp dir, merged into the workspace keeping `AGENTS.md` + `docs/`).
- `Package.swift`: one library product `stupid_torrent_client` (targets `stupid_torrent_client` app target) + `torrent-cli` executable product (xtool ignores executables). Targets: `Bencode`, `TorrentCore` (dep: Bencode), `Streaming` (dep: TorrentCore), `stupid_torrent_client` (SwiftUI `@main`, deps: TorrentCore, Streaming), `torrent-cli`, `TorrentTestingSupport` (path `Tests/TorrentTestingSupport`), test targets `BencodeTests`, `TorrentCoreTests`. swift-tools 6.0; platforms iOS 17 / macOS 14.
- `xtool.yml`: bundleID `com.stupidtech.stupid-torrent-client`, product `stupid_torrent_client`, `infoPath: Info.plist`.
- Custom `Info.plist`: `UIBackgroundModes` audio, `magnet` URL scheme, `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, ATS `NSAllowsArbitraryLoads` (for HTTP tracker announces via URLSession), `NSLocalNetworkUsageDescription`.
- `.gitignore` updated (`/third-party/`, `/seeder-cache/`). `git init` (no commit yet).
- Committed fixture `Fixtures/big-buck-bunny.torrent` (21KB, from webtorrent.io).
- Reference clones in gitignored `third-party/`: `webtorrent` (JS), `anacrolix-torrent` (Go).
- Gate passed: `swift build`, `swift build --product torrent-cli`, `swift test` (placeholder tests).

### Phase 2 — Bencode + Metainfo + Magnet (done)
- `Bencode`: strict decoder (rejects leading zeros, `-0`, trailing data, truncation, excessive depth) + canonical encoder (dict keys byte-sorted). `Bencode.rawValue(forKey:in:)` slices the raw info-dict bytes for info-hash computation (mirrors anacrolix `InfoBytes` + strict `ReadEOF`).
- `Metainfo` (+ `TorrentFile`): parses `.torrent` per BEP 3, mirroring anacrolix behavior — raw info bytes -> SHA-1 info hash (CryptoKit `Insecure.SHA1`), `name.utf-8` over `name`, `files` precedence over single `length`, per-file offsets, `trackerTiers` from `announce-list`/`announce` with override semantics. `FileLayout`-style helpers: `byteRange(ofFileAt:)`, `pieceRange(forByteRange:)`, `location(piece:pieceOffset:)` for pieces spanning file boundaries.
- `MagnetLinkParser`: mirror anacrolix — scheme must be `magnet`, first `xt=urn:btih:` wins, hex(40)/base32(32) decode, `dn` first value, `tr` list, `xs`; `+` decodes to space (Go `url.ParseQuery` semantics).
- Tests (14, all green): bencode round-trip/malformed/depth/raw-slice; BBB fixture parses to info-hash `dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c`, 1055 pieces, 3 files, 8 announce tiers; piece-spanning file mapping across srt->mp4 and mp4->poster boundaries; magnet hex + base32 parse.
- `TorrentTestingSupport` gains a `Fixtures` helper (locates `Fixtures/` from `#filePath`).
- Two test-fixture bugs were fixed during debugging (wrong string lengths), no parser changes needed.

Next: Phase 3 — `PeerWire` message codec, `Peer` (`NWConnection`), HTTP+UDP `Tracker`, sparse `Storage`, sequential `PiecePicker`, mock trackers + loopback seeder harness in `TorrentTestingSupport`.

## 2026-08-06 — Phase 3: wire protocol, trackers, storage, download engine (live + hermetic verified)

### Transport: BSD sockets, not Network.framework
- `NWConnection` (Network.framework) **does not reach `.ready` in this dev shell** — it depends on XPC to networkd/nehelper, which the opencode bash sandbox denies (python/nc/curl via BSD sockets work fine; a standalone NWConnection TCP/UDP test hung at `.preparing`). Rewrote the transport on raw BSD sockets (`BSD.swift`: `TCPSocket` with poll()-based connect timeout, `UDPSocket` with `SO_RCVTIMEO`, `TCPListener`). Same code works on iOS. This is environment-driven, not a "fake problem": the `torrent-cli` dev harness runs in this shell, so BSD is the only testable path; it also turned out simpler (no `UDPConnection`/task-group timeout dance).
- `PeerStream`: BSD TCP + a background reader thread feeding a lock-protected buffer; `read(exactly:)` suspends via continuation until enough bytes arrive.

### Engine (all in `TorrentCore`)
- `PeerWire` codec (length-prefixed framing, IDs 0-9 + extended 20), `Handshake`, BEP 3 semantics. Golden-bytes unit tests.
- `PeerSession` (per-connection state machine: handshake, interested, choke/unchoke, batched request pipeline, piece handling, basic seeding via `readVerifiedPiece`).
- `Tracker`: `HTTPTrackerClient` (URLSession, compact peers/peers6, interval, events) + `UDPTrackerClient` (BSD UDP, connect->announce, txn matching). `TrackerClientFactory` dispatches by scheme. CLI `tracker` command verified: explodie returns 78 seeders for BBB.
- `Storage` (actor): sparse multi-file writes via pwrite, piece->file slices across boundaries, SHA-1 verify (CryptoKit), verified-bitfield sidecar for resume, disk-space guard.
- `PiecePicker` (sequential) + `Torrent` actor: announce loop, peer fan-out (fire-and-forget `considerPeer`), block allocation via shared per-piece cursor, verify-on-complete, requeue on failure, `StatusBroadcast` fan-out, BSD `TCPListener` for inbound.
- `torrent-cli`: `add` (with `--dir`, `--stop-at`, `--peer host:port` injector, `--verbose`), `verify` (`PieceVerifier`), `tracker`.

### Two real bugs found & fixed
1. **Data-slice traps (SIGTRAP / hangs)**: `PeerMessage.decode` used `body.dropFirst()` (a `Data` slice with `startIndex == 1`) and indexed it 0-based (`.port`/`.extended` cases) and via `subdata(in:)` (`int32(at:)`) — both trap/misbehave on slices. Fixed by copying to fresh `Data(body.dropFirst())` in decode and making `int32(at:)` use `startIndex`-relative byte reads. This was the cause of the live-swarm "stall" and the test-suite signal-5 crash.
2. **Request-pipeline stall**: `refillPipeline` sent each request with an `await stream.send` (detached task per send) — 48 serialized sends kept the receive loop from draining the peer's flood → TCP backpressure stall. Fixed by batching all pending requests into one `Data` and one send.

### Verification
- **Hermetic single-file** (aria2c seeder, 2MB, 128 pieces): `ok=128 bad=0 missing=0` at ~2.1 MB/s.
- **Hermetic multi-file** (3 files, 153 pieces, files spanning piece boundaries): `ok=153 bad=0 missing=0`.
- **Live BBB swarm** (276MB, 1055 pieces): downloads at ~300-850 KB/s from 121 seeds; 44+ pieces verified during the window. `tracker.opentrackr.org:1337` UDP is flaky (intermittent timeouts); explodie.org is reliable.

### Known issue (polish, Phase 8)
- Live swarms include **poisoning peers** sending corrupt blocks; our dedup-keeps-first-block means a bad block wins over a later good one, leaving some pieces failing SHA-1 (requeued repeatedly). Fix: on piece verify failure, ban/blacklist the peers that supplied its blocks and redownload from the rest. Note the hermetic path is 100% clean, confirming storage/engine correctness.
- `--stop-at` overshoots (in-flight pipelines drain past the cap) — acceptable; also connects to our own public IP returned by trackers (self-connect noise, harmless).

Next: Phase 4 (multi-file resume/fast-resume validation, hermetic + live) — most machinery already exists.

## 2026-08-06 — Phase 3 gate passed: full live BBB download, all 1055 pieces verified

- **Live swarm success**: `torrent-cli add Fixtures/big-buck-bunny.torrent` downloaded the full 276MB multi-file torrent from the live swarm (~1 MB/s from ~75-122 seeds) and `verify` reported `ok=1055 bad=0 missing=0`. All three output files match their expected sizes exactly (mp4 276,134,947 B, srt 140 B, poster 310,380 B), and the srt content is correct. **This closes the Phase 3 gate.**
- **Announce cadence fix**: the announce loop was sleeping for the tracker's full `interval` (~1800s) after the first announce, so when initial peers dropped the pool starved for 30 min. Re-announce now caps between 60-90s, keeping the peer pool fresh.
- **Poisoning-peer defense**: on piece SHA-1 verify failure, the peers that supplied that piece's blocks are disconnected and banned, and the piece is requeued (with a 5-attempt cap). Reduces corruption and avoids infinite requeue loops.
- **Resume persistence**: verified-bitfield sidecar is now flushed periodically (on the 1s tick when dirty) and on stop, so a kill mid-download doesn't lose verified-piece state.
- **Clarification on `bad` pieces in earlier partial runs**: with `--stop-at`, the highest-indexed pieces are often mid-flight at stop; later writes make the file long enough that `verify` reads zero-filled holes for unwritten blocks → reported `bad`. These are *incomplete* pieces, not corruption. A full run has zero bad.

Next: Phase 4 (resume/fast-resume validation, hermetic + live) — machinery exists; add kill/relaunch resume test + bitfield round-trip unit test.

## 2026-08-06 — Phase 4: resume / fast-resume validated (hermetic)

- **Resume bug found & fixed**: `Storage.loadVerified` passed `data.dropFirst(4)` (a `Data` slice with `startIndex == 4`) to `Bitfield.from`, which indexes 0-based → failed to load, so relaunches re-downloaded everything. Fixed with `Bitfield.from(Data(data.dropFirst(4)), ...)`. (Audited all slice usages in the codebase; this was the last one — the others copy or index correctly.)
- **Bitfield round-trip unit tests** added (`BitfieldTests`): wire-format round-trip, MSB-first bit ordering, partial-byte padding. 21 tests total, all green.
- **Resume validated hermetically** with a 50MB / 800-piece torrent:
  - Sidecar is flushed periodically (1s tick when dirty) and on stop.
  - Test A: relaunch on a complete download loads the bitfield and finishes instantly (no re-download).
  - Test B: sidecar truncated to 400/800 bits, relaunch resumes from 50%, downloads the remainder, `Verify: ok=800 bad=0 missing=0`.
  - Live resume exercised implicitly during the full BBB run (sidecar saved mid-download).
- Note: local loopback seeding is so fast (52 MB/s) that `--stop-at` and SIGTERM don't reliably interrupt mid-download; the sidecar-truncation approach is the deterministic way to test resume.

Phase 3 gate (live BBB, 1055/1055) and Phase 4 gate (resume) both pass. Next: Phase 5 — ut_metadata (BEP 9/10) + magnet flow.

## 2026-08-06 — Phase 5: ut_metadata (BEP 9/10) + magnet flow — gate passed

- **`MetadataExchange`**: extended handshake (BEP 10) build/parse, ut_metadata (BEP 9) request/data message build/parse (`Bencode.decodeFirst` added to split the bencoded dict prefix from the raw chunk), and `MetadataFetcher` (connect, negotiate, request 16KiB metadata pieces, assemble, SHA-1-verify against the info hash).
- **`Metainfo` refactor**: added `init(infoDict:trackers:)` to build metainfo from a raw bencoded info dict (the magnet case), sharing parsing with `init(data:)`.
- **`MagnetBootstrapper`**: magnet -> announce to its trackers -> try peers for ut_metadata -> `Metainfo`. CLI `add` now accepts `magnet:` links.
- **Bugs found & fixed**:
  1. **BEP 9 id directionality**: the extended id is negotiated per-direction — peers send metadata to us with *our* advertised id (1), not theirs. Fixed the receive filter; requests still use their id.
  2. **`explodie` rejects `port=0`** announces ("Port can't be 0") -> bootstrap now announces port 6881.
- **Hermetic**: `add <magnet for 50MB torrent> --peer 127.0.0.1` fetched metadata from aria2 and downloaded 800/800, `ok=800 bad=0`.
- **Live BBB magnet**: `add magnet:?xt=urn:btih:dd8255...&tr=udp://explodie.org:6969&tr=udp://tracker.opentrackr.org:1337` fetched the info dict from the real swarm (2 chunks, 16384+4923 bytes), downloaded all 1055 pieces (~1.4 MB/s), `Verify: ok=1055 bad=0 missing=0`. All three files match expected sizes exactly.
- Unit tests: extended-handshake advertise/parse, ut_metadata request bytes, data-message parse (dict+chunk split), fixture info-dict 16KiB chunk/assemble + `Metainfo(infoDict:)` round-trip. 25 tests total, all green.

Next: Phase 6 — streaming (AVAssetResourceLoaderDelegate + priority window + moov-tail) and Player.

## 2026-08-06 — Phase 6: streaming — gate passed

- **TorrentCore streaming API** (`Torrent+Streaming.swift`): `fileName`/`fileSize` (nonisolated), `streamPriority(fileIndex:range:)` (adds the covering pieces to the picker's priority set so the player's window/moov tail download ahead of the sequential cursor), `streamingAvailability(fileIndex:offset:)` (contiguous verified run), `streamingRead(fileIndex:offset:length:)` (verified-byte reads via new `Storage.read(bytes:)`). `PiecePicker` gained a `priority` set served before sequential.
- **Streaming target** (`TorrentStreamSession.swift`): `TorrentResourceLoaderDelegate` (AVAssetResourceLoaderDelegate) serving a custom-scheme `AVURLAsset`. Provides contentInformation (type/length/byte-range), feeds verified bytes as they become available (200ms poll on the actor for the next verified run), prioritizes each requested range, handles `requestsAllDataToEndOfResource` (keeps the request open until the file completes), and finishes on cancellation. `TorrentStreamSession` owns the delegate (delegate must stay alive for AVURLAsset).
- **CLI `stream-test`**: downloads a partial file (`--seed-until`), starts a second torrent on the same dir (loads the verified bitfield, continues downloading), then loads `AVURLAsset` `.duration`/`.isPlayable` and reports. Unbuffered stdout + a 30s asset-load timeout.
- **Fixes during Phase 6**:
  1. Over-aggressive poisoning ban could disconnect good peers when one poison block corrupted a shared piece -> banning is now threshold-based (ban only peers with >=2 failed-piece incidents).
  2. `--stop-at` used received-byte count, which could stall just below the threshold -> now breaks on *verified* bytes.
- **Validation**: generated a real 3.5MB H.264/AAC test mp4 (ffmpeg, faststart), tracker-less torrent, aria2 seeder. `stream-test --seed-until 1MB` downloaded to 167/214 pieces (78%), then `ASSET: duration=30.0s playable=true` — **media loads and is playable before 100% download**.
- Note: live-swarm tests were getting entangled with flaky trackers/poison peers, so the streaming gate uses a tracker-less hermetic setup (only the injected seeder). 25 tests green; full package builds.

Next: Phase 7 — SwiftUI app (torrent list/detail/add/player) on the device.

## 2026-08-06 — Phase 7: SwiftUI app (built, deploy pending device)

- **`TorrentItem`** (@MainActor @Observable, Identifiable+Hashable): wraps a `Torrent` actor + `Metainfo`; subscribes to `statusBroadcast` and runs `torrent.run()` in a background task; `stop()`/`pauseResume()`. Stored `let` props marked `nonisolated` for Swift 6.
- **`TorrentStore`** (@MainActor @Observable): Documents-based persistence — `Documents/downloads` (data), `Documents/torrents` (`.torrent` copies). `restore()` reloads saved `.torrent` files on launch; `addMagnet` (bootstrap via `MagnetBootstrapper`), `addFile` (security-scoped `fileImporter`), `remove`. `Metainfo` gained `infoDict` + `torrentData()` to persist a resolved magnet as a `.torrent` (avoids re-bootstrapping on relaunch).
- **Views** (`Views.swift`): `ContentView` (torrent list w/ progress/speeds/peers, swipe-delete), `AddTorrentView` (magnet paste + `.torrent` file importer), `TorrentDetailView` (status + per-file rows with a play button for AVPlayer-streamable types), `PlayerView` (SwiftUI `VideoPlayer` fed by `TorrentStreamSession`). Minimal styling per project rules.
- **Fix during Phase 7**: `AVPlayerViewController` is absent from this macOS SDK (host `swift build`), so `PlayerView` uses cross-platform SwiftUI `VideoPlayer`. Also replaced iOS-only `fullScreenCover` with `sheet` for host-build compatibility.
- **Deploy**: `xtool dev run --network -u 00008130-001C4CA030A1401C` builds and packages successfully (`xtool/stupid_torrent_client.app`, bundle ID `com.stupidtech.stupid-torrent-client`, custom Info.plist keys merged, iOS 17). The network install hangs because **the device is currently offline** (`xtool devices` returns none) — deploy pending device availability/unlock. Everything compiles; 25 tests green.
- New public APIs on TorrentCore for the app: `Metainfo.infoDict`/`torrentData()`, `Data.hexString`, `Torrent.contentType(forFileNamed:)`, `Torrent.metainfo`/`statusBroadcast` made `nonisolated`.

## 2026-08-06 — Streaming + resume fixes (simulator validation)

### Streaming loader rewrite (`TorrentStreamSession.swift`)
The original loader fed the *entire* available run in one `respond(with:)` and held all-to-end requests open with a single pre-computed `end`, which broke on real AVPlayer request patterns. Rewrote `serve()` to handle the three request shapes:
- **All-to-end** (`requestsAllDataToEndOfResource`): keep the request open, feed capped 512KB chunks as pieces verify, until the file completes (progressive playback).
- **Bounded** (`requestedLength > 0`): feed exactly the requested range, then `finishLoading`.
- **Probe** (`requestedLength == 0`, not all-to-end): serve what's available, then `finishLoading` so AVPlayer re-requests (this is what the moov/duration probe needs).

Track the offset locally (follow `currentOffset` only if the player jumps ahead) so we never re-feed or over-feed.
- Regression found during validation: a `requestedLength == 0` non-all-to-end request was being held open with zero bytes served -> `finishLoading` -> "play button with slash" / asset load failure. Fixed by the probe case above.
- Verified in simulator: playback smooth with ~76s buffered ahead (CoreMedia log); `stream-test` reports `duration=30.0s playable=true`.

### Resume bug (real, the download kept restarting from 0)
`Torrent.completePiece` marked `picker.verified` but **never `storage.markVerified`**, so `saveVerified()` always wrote an all-zero bitfield -> the sidecar never persisted progress -> every relaunch re-downloaded. (My earlier Phase 4 "resume works" test was fooled by fast loopback re-downloads.) Fixed: `completePiece` is now `async` and calls `await storage.markVerified(piece)`. Verified: sidecar now persists 214/214 bits and relaunch resumes in 0.02s.

### App notes
- App target now sets `TorrentLog.verbose = true` (dev aid; remove before release if noisy).
- `xtool dev run --simulator` reinstalls appear to create a fresh data container each time, so repeated reinstalls reset the download; the app itself downloads and streams correctly once running.

## 2026-08-06 — App polish session (simulator UX + release prep)

- **Full BBB download completed in the app** (1055/1055 verified, mp4 276,134,947 B) — confirmed the engine runs the whole lifecycle in the simulator.
- **Root cause of "reinstall resets the download"**: it does *not* — iOS migrates the app's data container on update (verified: `.torrent`, mp4, and sidecar all survive; only the container UUID changes). The perceived resets were the (now-fixed) sidecar bug where `saveVerified` always wrote 0 bits, so every relaunch re-downloaded.
- **App title**: `CFBundleDisplayName` set to "stupid torrent" in the custom `Info.plist`.
- **Audio session**: `PlayerView` configures `AVAudioSession` to `.playback` (mode `.moviePlayback`) — fixes the muted/unresponsive volume control (iOS defaults to `.soloAmbient`).
- **Picture-in-Picture**: iOS player switched to `AVPlayerViewController` (guarded by `#if os(iOS)`; macOS host build keeps `VideoPlayer` since `AVPlayerViewController` is absent from this macOS SDK). `allowsPictureInPicturePlayback = true`; relies on the existing `audio` background mode.
- **Player presentation**: fullscreen on iOS (`.fullScreenCover`), sheet on macOS.
- **File rows (detail view)**: only streamable files get a play icon; the whole row is a play button (no greyed-out icon on unplayable files).
- **Completed torrents**: list row and detail "Status" section hide progress/stats when `status.isComplete`; only the name (list) and Files (detail) remain.
- **Dev aid**: app sets `TorrentLog.verbose = true` (remove for release if noisy).

## Unreleased

(New entries go here as work progresses.)
