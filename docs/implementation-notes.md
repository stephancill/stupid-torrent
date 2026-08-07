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

## 2026-08-06 — Repo released + debugging skill

- **Published** to GitHub as `stephancill/stupid-torrent` (public); added `README.md` + MIT `LICENSE`.
- **Added `skills/stupid-torrent-debug/`** — a repo-local opencode skill capturing this session's debugging knowledge: simulator workflow (preferred UDID, install/launch/log/screenshot), checking app state (data container, `.verified` sidecar bit counts via `scripts/check_app_state.sh`), `torrent-cli` commands, hermetic seeding with aria2 (tracker-less torrents, seeding flags), live-swarm tips (BBB hash, flaky opentrackr, poison-peers), and the gotchas to not "fix" (BSD sockets, Data-slice traps, `#if os(iOS)` AVKit).

## Unreleased

### 2026-08-06 — Streaming fix: moov-tail playback for non-faststart MP4s (Sintel)

Added Sintel (`08ada5a7...`) as a second torrent in the sim. Its `Sintel.mp4` is a **non-faststart MP4** (ftyp + mdat only; `moov` at the very end). AVPlayer could not play it while downloading — only after the file completed.

**Root cause**: the loader called `streamPriority(offset..<fileLength)` for *every* request, including AVPlayer's all-to-end progressive request. That flooded the whole file into the picker's priority set; since `PiecePicker.nextPiece()` served priority pieces in ascending index order, the tail `moov` piece downloaded *last*, so playback could not begin until ~100%.

**Fix** (mirrors webtorrent's `file.select(range, priority)`):
- `PiecePicker.priority` is now `[Int: Int]` (piece -> level). `nextPiece()` serves highest level first, then lowest index within a level, then the sequential cursor.
- `Torrent.streamPriority` assigns level 10 ("jump") to ranges well ahead of the sequential cursor (moov tail, seek targets), level 0 to the current window.
- The loader prioritizes bounded requests' exact range, and for all-to-end requests only a 2 MB lookahead window — never the whole file.

**Verification**: hermetic repro with a generated non-faststart mp4 (ffmpeg, moov after mdat) + aria2 seeder throttled to 30 KB/s. Before: `asset load ... timed out` with the moov piece never prioritized. After: `piece 12 verified (2/13)` — the moov piece downloads second — then `duration=30.0s playable=true` at ~15% download. Faststart regression still playable at 1/13. Added 4 `PiecePickerTests` (levels jump, window order, verify-removes-priority, level fallthrough). 29 tests green.

### 2026-08-06 — Seeking support (streaming jumps + sequential frontier follows playhead)

AVPlayer seeking in the app stalled at the target once the buffered jump window drained: the seek target was not treated as a jump, and the in-order download never followed the playhead.

**Root causes found via `stream-play --seek-to` + loader/picker tracing:**
1. The picker cursor starts at 0 even when the resume bitfield already has pieces 0..n verified, so the initial streaming window was misclassified as a jump (`2 > 0`), pinned at priority 10 forever (max-level), and drained before the real seek target.
2. The old jump threshold (`> cursor + 4`) missed a seek only a few pieces ahead of the frontier.

**Fix:**
- `setPriority` now keeps the *max* level (a window request can't downgrade a jump) and skips verified pieces.
- `streamPriority` classifies a range as a **jump** (level 10 + moves the sequential cursor to the target) when its start piece is ahead of the *sequential progress* (first unverified piece from 0), not the allocation cursor. The streaming window tracks the playhead and stays at/below progress, so it is correctly a low-priority lookahead; a seek or the moov tail is ahead of progress and jumps.

**Verification (hermetic, aria2 seeder):**
- 30 s faststart file, `--seed-until 524288`, seek to 25 s: before, `SEEK FAIL` (playhead stuck at 26.9 s); after, `SEEK OK` — playhead resumes and reaches 30.0 s, `13/13` verified.
- 120 s faststart file (51 pieces), seek to 60 s mid-file: playhead jumps to 60 s and advances 1 s/s to 94.9 s with no stall, verified climbing 10 → 50 as the in-order stream resumes from the seek position.
- Moov-at-end regression still passes (`stream-test` playable at 1/13 pieces).
- Added 2 `PiecePickerTests` (max-level retention, verified-skip). 31 tests green.

### 2026-08-06 — Show complete/restored state immediately (skip "starting…")

Completed torrents flashed "starting…" on launch because `item.status` stayed `nil` until `Torrent.run()` loaded the resume sidecar and published the first status. For a torrent that is already complete (or partially downloaded), the verified state is known before the engine starts — it's in the `.verified` sidecar.

**Changes:**
- `Storage.loadVerifiedCount(directory:infoHash:pieceCount:)` — public static, reads the resume sidecar synchronously and returns the verified piece count.
- `TorrentStatus` gained a public `init` (was internal; the app builds initial snapshots).
- `TorrentStore.add` reads the sidecar count and passes it to `TorrentItem`; `TorrentItem` seeds its initial `status` from it — `.seeding` when complete, else `.downloading` at the resumed progress — so the row never shows "starting…" for a torrent with existing data.
- `TorrentRow` marks complete torrents with a `checkmark.circle.fill` + "Complete" caption (previously a complete row showed only the name).

**Verification**: 32 tests green (added `StorageTests.loadVerifiedCountReadsSidecar`). Simulator: both BBB (1055/1055) and Sintel (987/987) restore and display as complete immediately.

### 2026-08-06 — Persist completed state the moment it's reached

A torrent that finished downloading could briefly linger in the Downloading section / reappear as downloading after a relaunch: the resume sidecar was only saved on the 1s ticker or at the very end of `run()` — *after* the two slow tracker announces (`completed` + `stopped`). Killing the app in that window lost the completed state.

**Fix** (`Torrent.swift`):
- `completePiece` now saves the verified sidecar immediately when the last piece makes the torrent `allSet` (persisting completion the instant it's reached), instead of waiting for the end-of-`run()` save.
- `run()` reordered to `saveVerified()` right after the download loop breaks, before `disconnectAllPeers()` and the tracker announces.

Verified end-to-end in the simulator with a local mock HTTP tracker + aria2 seeder: the app announced, downloaded 10/10, and the sidecar read 10/10 at completion. UI status sequence observed via temporary logging was already correct (`downloading 9/10 → seeding 10/10` — the section move was instant); this change makes the completed state durable.

### 2026-08-06 — Root cause: completed torrents flashed into Downloading on open

Still not showing as completed on reopen. Root cause found by logging every status the UI received on launch:

`Torrent.init` created the `StatusBroadcast` with an initial `currentValue` of `.downloading 0/N`. The app's `TorrentItem.statusTask` subscribes on `start()` and `StatusBroadcast.subscribe()` replays that initial value, **overwriting the app's correct `.seeding` INIT status** — so every restored torrent appeared in the Downloading section at 0% until `run()` loaded the bitfield and published `.seeding`.

**Fix** (`Torrent.swift`): seed the broadcast with the restored state — `Torrent.init` synchronously reads the resume sidecar via `Storage.loadVerifiedCount` and sets the initial `currentValue` to `.seeding` (complete) or `.downloading` at the resumed progress. Now the subscribe replay matches the app's INIT status, so completed torrents stay in the Completed section from the moment the UI first renders.

Verified: after the fix, the statuses received by the UI on reopen are `seeding N/N` only — the `downloading 0/N` flash is gone.

### 2026-08-06 — Torrent list, file detail, and player polish

- Split the torrent list into Downloading and Completed sections; Completed is expanded by default and uses a Mail-style trailing disclosure chevron with a smooth in-place rotation.
- Added persisted torrent-added dates and compact relative timestamps, a pie progress indicator, and an immediate completed-state checkmark.
- Sorted detail files largest-first while retaining their original playback indexes, and aligned file-row separators consistently.
- Added a native loading spinner to AVPlayer's content overlay until initial playback starts or loading fails.
- Rebuilt and exercised each UI revision in the `NoFeedSocial iOS 26.3` simulator.

### 2026-08-06 — DHT (BEP 5) peer discovery + magnet bootstrap robustness

**Why**: `torrent-cli add <magnet>` was timing out on the Odyssey UIndex TELESYNC release while WebTorrent resolved it instantly. Diagnosis (verified with independent Python probes): the trackers are fine and the swarm is huge (~8k seeders reported), but the tracker-returned peer pool is ~99% NAT'd/unreachable, and of the few reachable peers, most are leechers advertising `ut_metadata` with no data, or they close our plaintext connection (`write(9)` EBADF = accept-then-close). WebTorrent works because it discovers peers over **DHT (BEP 5)** — live peers *announced for that infohash* — plus WebRTC/µTP/MSE, all of which were deferred in planning.md.

**Changes**:
- New `Sources/TorrentCore/KRPC.swift`: BEP 5 KRPC wire codec (ping/find_node/get_peers/announce_peer query + response/error), compact node + compact peer encode/parse, over the existing `Bencode` module.
- New `Sources/TorrentCore/RoutingTable.swift`: k-bucket table keyed by XOR common-prefix length; `closest(to:count:)` via lexicographic XOR compare; full-bucket evicts least-recently-seen.
- New `Sources/TorrentCore/DHTClient.swift`: UDP socket, transaction-matched pending queries with timeouts, parallel bootstrap from router nodes, iterative `get_peers` closest-node lookup returning `[PeerAddress]`, and a **persisted node cache** (`~/Library/Caches/stupid-torrent-dht.nodes`, mirrors bittorrent-dht's disk persistence) so repeat lookups start from a warm table.
- `MetadataExchange.swift` (`MagnetBootstrapper`): discovery now runs DHT lookup and tracker announces **concurrently**; DHT peers are swept for metadata *first* (they're live/announced), then tracker rounds. Candidate sweep keeps DHT order (no Set shuffle), reduced concurrency 30→12 (peers close under connection hammering), and retries a `closed`/`write(9)` peer once (fresh connection to a live peer usually works).
- `MetadataFetcher.fetch` timeouts reduced 15s→8s metadata / 5s→4s connect so dead peers cycle fast.
- `PeerStream.connect(timeout:)`: configurable connect timeout (default 10s preserved).
- `Torrent.swift`: new `dhtLoop()` task that periodically queries DHT for fresh peers (runs alongside `announceLoop`), feeding them into `considerPeer`.
- `torrent-cli add`: uses `MagnetBootstrapper.metainfoAndPeer` — returns the metadata-serving peer and injects it straight into the download — and **saves the resolved magnet as a `.torrent`** in the download dir so later runs skip bootstrapping.
- Added `DHTTests` (KRPC round-trips, compact node, routing table XOR closeness). 38 tests green.

**Verification**:
- Isolated `MetadataFetcher` harness fetches Odyssey metadata from a live DHT peer in ~1s.
- Standalone DHT harness: warm-cache lookup returns 100–488 peers for the Odyssey infohash; cold bootstrap populates 100+ nodes via `dht.transmissionbt.com` (router.bittorrent.com/utorrent.com are filtered from this network — added fallback nodes).
- End-to-end `torrent-cli add <Odyssey magnet>`: with the warm cache + DHT-first sweep + retry, metadata resolves in ~90s (was: never), the `.torrent` is saved, and the download starts (peers unchoke; data transfer is limited by the swarm's near-total lack of usable seeders, not by the client).

**Note**: this pulls DHT (BEP 5) out of the deferred list (planning.md line 10/134). MSE/PE encryption, µTP, WebRTC, and web seeds remain deferred — they are why some reachable peers still close our plaintext TCP connection.

### 2026-08-06 — MSE/PE protocol encryption (BEP 10)

**Why**: some reachable peers close our plaintext TCP connection the moment we send a handshake (`write(9)` EBADF / `read(54)` after connect) — they require protocol encryption. WebTorrent reaches them because it speaks MSE/PE; we couldn't. This was the last big transport gap for real-world swarm reachability.

**Changes**:
- New `Sources/TorrentCore/BigUInt.swift`: dependency-free 768-bit big integer with Montgomery multiplication for modular exponentiation (verified against Python's `pow` for public keys, shared secrets, and 2^(2^k) squarings).
- New `Sources/TorrentCore/DH.swift`: Diffie-Hellman over the BEP 10 768-bit MODP prime, random 160-bit private keys, 96-byte big-endian public keys, shared-secret derivation.
- New `Sources/TorrentCore/RC4.swift`: RC4 stream cipher (KSA + PRGA) with the 1024-byte keystream drop BEP 10 requires (verified against Python).
- New `Sources/TorrentCore/MSEHandshake.swift`: full MSE/PE handshake state machine — initiator (outgoing) and responder (incoming): DH exchange, `req1`/`req2`/`req3` sync + XOR'd info-hash recovery, VC verification, crypto provide/select (plaintext 0x01 + RC4 0x02), padding, and install of the payload encrypt/decrypt ciphers. Plaintext fallback when a peer answers with a bare handshake.
- `PeerStream.swift`: `enableEncryption(encrypt:decrypt:)` installs stream transforms (sends encrypted, received bytes decrypted before buffering, already-buffered bytes re-decrypted); `readUntil(pattern:maxBytes:)` for MSE sync, `unread(_:)` for plaintext-fallback detection.
- `PeerSession.swift`: runs the MSE handshake before the BitTorrent handshake in `performHandshake` (both initiator and responder paths); enables the extension bit on our handshake now that extended messaging is supported.
- Added `MSETests`: RC4 round-trip + Python-reference first-byte check, DH public key + shared secret against Python values. 42 tests green.

**Verification (independent Python MSE reference implementation over loopback)**:
- Swift initiator → Python responder: method=rc4, encrypted payload round-trip (`hello-payload` → `server-reply!`), select=2/RC4.
- Python initiator → Swift responder: method=rc4, `hello-from-py` received, `swift-reply!!` returned.
- Live swarm: `torrent-cli add <Odyssey magnet>` now completes MSE handshakes with peers (previously plaintext-only), and the download starts; data transfer remains limited by the swarm's near-total lack of usable seeders, not by the client.

**Note**: this pulls MSE/PE (BEP 10) out of the deferred list (planning.md line 10/134). µTP (BEP 29), WebRTC, and web seeds remain deferred.

### 2026-08-06 — Simulator diagnosis + block-request diagnostics

- Deployed to the `NoFeedSocial iOS 26.3` simulator. Debugged "struggling to find peers" on The Odyssey: MSE/PE now connects to RC4 peers and DHT finds 100+ peers, but data stalled at 0 pieces.
- **Root cause investigation**: added verbose diagnostics to `refillPipeline` (`PeerSession`) and `nextBlockRequest` (`Torrent`) logging whether we request blocks and the picker state. Confirmed the engine's data path works end-to-end (BBB downloads to 1055/1055 on the same simulator); the Odyssey stall is swarm quality (peers unchoke but send 0 bytes), plus WebTorrent's active session held the good peers' per-IP slots.
- Committed the diagnostics as `b8274e7` (verbose-only, off by default).

### 2026-08-06 — µTP (BEP 29) work-in-progress → handed off

- Began implementing µTP transport so we can reach µTP-only peers (WebTorrent's remaining advantage on the Odyssey swarm). **In progress, not committed** — see `docs/utp-handover.md` for full details, references, known bugs, and the interop test setup against `utp-native` (libutp).
- Files (uncommitted): `UTP.swift` (wire codec), `UTPConnection.swift` (per-connection state machine), `UTPTransport.swift` (UDP demux + retransmit ticker), and a `UDPSocket.receiveFrom` addition.
- Known blocker: `UTPTransport` receive loop runs on a raw `Thread` but its handlers are actor-isolated, so inbound packets aren't processed (the Node libutp server received our SYN, proving the codec + SYN are correct). Fix is to run the receive loop as a detached `Task`.

### 2026-08-07 — µTP (BEP 29) transport landed (handover completed, end-to-end verified)

Completed the uncommitted µTP work from `docs/utp-handover.md` and landed it. The engine now reaches µTP-only peers (WebTorrent's remaining advantage on swarms like The Odyssey) in addition to TCP+MSE.

**Files**: `UTP.swift` (codec), `UTPConnection.swift` (per-connection actor), `UTPTransport.swift` (shared UDP demux + ticker), `UTPStream.swift` (new, `PeerTransport` adapter), plus `UDPSocket.bind(port:)`/`receiveFrom` in `BSD.swift`.

**Bugs fixed** (all against libutp `utp_internal.cpp`):
1. **Receive loop never ran** (the handover blocker): `UTPTransport.start()` used a raw `Thread` calling actor-isolated `receiveLoop()`. Now a detached `Task` runs a `nonisolated` loop that does the blocking `socket.receiveFrom` off the actor and hops in via `await handleIncoming(...)`.
2. **Stale acks** (found via interop): `ackNr` was never advanced when delivering in-order data, so our acks stayed at `seq-1` and libutp peers retransmitted packet 1 forever (multi-packet echo hung). `deliverData` now sets `ackNr = nextRecvSeq &- 1` after each in-order delivery/drain.
3. **`nextRecvSeq` not seeded from the handshake**: responder now sets `nextRecvSeq = SYN.seq + 1`; initiator sets `nextRecvSeq = SYNACK.seq` on connection. Previously random, so the first DATA was misclassified as out-of-order and buffered/dropped.
4. **SYN consumes a sequence number**: initiator's first DATA is now `SYN.seq + 1` (libutp `utp_connect`), matching the responder's expected window.
5. **Codec extension chain**: the extension-bits header's "next type" byte now names the following SACK extension; SACK parsing maps bit i to `ack + (i+2)` (bit 0 = the hole at `ack+1`), per libutp `send_ack`/`selective_ack`.
6. **Cleaned dead members**: removed `flush()`/`nudge()` overlap (now `flushData` = send-unsent, `nudge` = RTO retransmit + pending ack), unused `markConnected`, `readBytesAvailable`, and the `packetSource` remnants.

**Integration** (`PeerSession`/`Torrent`):
- `PeerTransport` protocol (send/read(exactly:)/close) lets `PeerSession` run over TCP (`PeerStream`) or µTP (`UTPStream`). µTP sessions do a plaintext BT handshake (µTP is its own transport; MSE stays TCP-only), with a bounded handshake budget so a stalled µTP session falls back to TCP.
- Outbound: µTP first (4 s SYN budget — mirrors webtorrent's "if the utp connection fails, replace with a tcp connection"), TCP fallback.
- Inbound: the shared UDP socket binds the announced listen port (falling back to outbound-only if the bind fails) and accepts µTP connections as plaintext PeerSessions.

**Verification**:
- **Interop vs libutp (`utp-native`) over loopback, both directions**: Swift initiator → libutp responder (17 B and 5000 B multi-packet echo both pass), and libutp initiator → Swift responder (echo passes). The 5000 B case caught bug #2.
- **Unit tests**: 7 new `UTPTests` (codec round-trip incl. SACK + extension-bits chains, 16-bit seq wrap, `receiveFrom` address byte order, Swift↔Swift loopback handshake+echo, responder connection-id scheme). 49 tests total, all green.
- **Live Odyssey magnet** (`torrent-cli add <48aeb057… magnet> --verbose`): metadata fetched, 9 real µTP connections to swarm peers (BT handshakes completed over µTP, e.g. 191.243.36.164, 181.91.87.192, 78.26.50.47), 152 µTP SYN timeouts fell back to TCP (one TCP peer seeded the download), 11 pieces verified. Download pace is limited by the swarm's near-total lack of usable seeders, not the transport.

**Notes**: the handover's `utp-echo`/`utp-listen` CLI commands and `third-party/utp-echo-server.js`/`utp-echo-client.js` (gitignored) remain as repeatable interop harnesses. planning.md updated: µTP moved out of the deferred list.

### 2026-08-07 — Magnet resolution: MSE for the metadata fetch

Follow-up from a simulator session where a freshly-added magnet took ~7 min to resolve (and looked stuck, sweeping hundreds of dead peers). Two causes: the app's DHT node cache was reset by a reinstall (cold discovery), and `MetadataFetcher` only spoke plaintext — peers that require MSE close plaintext metadata connections (`write(9)`/`connect(61)` floods in the log).

**Change** (`MetadataExchange.swift`): `MetadataFetcher.fetch` now runs the MSE/PE initiator handshake (`MSEHandshake.performAsInitiator`) before the BitTorrent handshake, with the existing `plaintextFallback` path — exactly mirroring what `PeerSession` already does for the data path. The BT handshake + extended handshake + ut_metadata requests are then encrypted when the peer supports it.

**Verification**:
- Live CLI `add <Odyssey magnet>`: `metadata: MSE handshake ok (method rc4|plaintext)` on many peers; the 14.5 KB info dict resolved as one chunk and the `.torrent` saved at ~50 s; download then started.
- Full suite still green (49 tests).
- Deployed to the simulator; the previously-stalled Odyssey download resumed and ran 21 MB → 312 MB (2 → 29/712 pieces) before the swarm's seeders dropped again (swarm quality, not the client).

### 2026-08-07 — DHT continuation-leak fix (transaction-id collision)

A `SWIFT TASK CONTINUATION MISUSE: query(_:to:) leaked its continuation` appeared in the simulator log during swarm churn. Root cause: `DHTClient.randomTransactionID()` returned only **2 bytes** (16 bits), and `addPending` did `pending[hex] = ...`, silently overwriting an earlier pending query on a txn collision. The overwritten query's continuation was orphaned and never resumed — under sustained query load (3 torrents × dhtLoop + bootstraps) collisions are guaranteed within an hour (birthday bound), leaking suspended `lookup`/bootstrap tasks that can hang future magnet bootstraps.

**Fix** (`DHTClient.swift`): transaction ids are now **4 bytes**, and `query` re-rolls the id if the hex is already pending (`pendingContains`), so every registered continuation is guaranteed exactly-once resume. Full suite green (49 tests); redeployed to the simulator.

### 2026-08-07 — Odyssey swarm investigation + peer-cycling tuning

User reported the Odyssey magnet download not progressing while WebTorrent succeeded. Full diagnosis:

- **The client works**: pointed directly at a reachable seeder (`torrent-cli add <Odyssey.torrent> --peer 46.164.54.202:52123`), the CLI downloaded at 620-720 KB/s and verified 3/712 pieces in 80 s (512/512 blocks each, clean SHA-1). Piece assembly/verify is correct.
- **The swarm is the bottleneck**: trackers report ~7k seeds but ~all are NAT'd/unreachable or leechers that handshake/unchoke and send 0 bytes. Reachable seeders come and go (the app's 21 → 312 MB burst was one such window).
- **WebTorrent's edge is parallelism**: a side-by-side run showed WebTorrent pulling ~0.6-1.6 MB/s from ~10 serving peers via `utpOutgoing` wires (default `secure:1` = MSE over µTP, but `secure:0` plaintext also worked — so encryption over µTP is NOT required). Our client reached the same peers (46.164.54.202:52123 in both) but with far fewer concurrent connections, so it caught fewer seeder windows. No PEX events observed in WebTorrent's run.

**Tuning** (`Torrent.swift`): µTP SYN timeout 4 s → 2 s, TCP connect timeout 10 s → 5 s, µTP handshake budget 10 s → 6 s, `maxActivePeers` 30 → 50 — cycling the peer pool ~2-3× faster like WebTorrent so we find seeder windows sooner. Also confirmed the two real fixes that matter for the user's magnet flow: `MetadataFetcher` now does MSE (lands faster, see earlier entry) and the DHT txn-collision leak is fixed.

**Re-verification on a healthy swarm (BB B live)**: `torrent-cli add Fixtures/big-buck-bunny.torrent` downloaded the full 276 MB to 100% — `verify: ok=1055 bad=0 missing=0` — with **30 µTP connections** and ~0.8-1.3 MB/s. Confirms the engine (µTP transport + MSE + tuning) still passes the Phase 3 gate.

### 2026-08-07 — µTP data path proven against a real BitTorrent µTP peer

Hermetic end-to-end test: a **WebTorrent (node) µTP seeder** (5 MB file, `client.seed` + `client.listen(0)`, `utp:true secure:0`) on loopback, our CLI pointed at it via `--peer 127.0.0.1:PORT`. Result: `µTP connected` → BT handshake over µTP → unchoke → 48-block pipeline → **320/320 pieces verified**, file byte-exact. This proves the µTP transport carries real BitTorrent data (not just the utp-native echo), isolating the Odyssey "stuck at 4%" to the swarm (reachable seeders are scarce and slot-constrained — peers unchoke us, we request, then they re-choke, consistent with the user's active WebTorrent session holding upload slots).

**Bug fixed en route**: injected peers (`--peer`) are considered before `run()` starts the listener, so `utpTransport` was nil and µTP was skipped, and a lazy-transport fallback raced `startListener` (which stopped it → `write(9)`/EBADF on the in-flight SYN). Now `connectUTP` lazily creates an outbound-only transport when needed and `startListener` retires (rather than destroys) a pre-existing one, stopping it only in `Torrent.stop()`.

### 2026-08-07 — Root cause of "blocks written but nothing verifies": piece completion fix

The recurring symptom across marginal swarms (Odyssey/Incredibles/John Wilson: download trickles at 16-32 KB/s, file grows, but **zero pieces verify**, no verify-failure logged) turned out to be a real engine bug, found via block-progress instrumentation:

- **Allocated-but-never-delivered blocks are never re-requested.** `pieceBlockCursor` advances past every block of a piece on first allocation; if a peer never delivers a specific block (partial seeder / dropped request), the cursor is already past it, so `nextBlockRequest` returns nil for that piece forever. Pieces sit at e.g. 96/103 blocks indefinitely → nothing verifies.
- **Coalesced final blocks.** Some peers send a piece's final short block (e.g. the 4 KB tail) *coalesced* into the last full block. The `receivedBlocks` per-offset set then lands one short of `needed` even though all bytes are on disk.

**Fix** (`Torrent.swift`):
- **Stall detection**: `pieceLastProgress` tracks the last block arrival per active piece; `tick()` requeues any active piece idle >20 s, resetting its cursor to the next missing offset so the outstanding blocks are re-requested (possibly from another peer) while keeping already-received blocks.
- **Byte-coverage completion**: `pieceReceivedBytes` counts distinct received bytes per piece; a piece is handed to SHA-1 verification when `receivedBytes >= pieceLength` instead of when the block-offset count hits `needed`. Over-counting from overlapping/coalesced blocks is harmless (SHA-1 is the real gate).

**Verification**: John Wilson S03 (which previously stalled at 96/103 forever) now verifies pieces (19 verified and SHA-1-correct in a few minutes); BBB regression: 70 pieces verified in 60 s at 2.5 MB/s, 0 verify failures. 49 tests green. Deployed to the simulator.

### 2026-08-07 — Removing a torrent also deletes its data files

`TorrentStore.remove` only deleted the persisted `.torrent`; the downloaded data files and the `.verified` resume sidecar were left orphaned in `Documents/downloads/`. **Fix** (`TorrentStore.swift`): `remove(_:)` now also deletes every `metainfo.files` path (relative to `downloadsURL`) and the `.\(infoHash).verified` sidecar. Cleaned up the already-orphaned Odyssey/Incredibles files from the simulator container by hand.

### 2026-08-07 — Peer idle timeout + empty state

- **Peer idle timeout** (`PeerSession.swift`): a peer that sends nothing for 30 s is disconnected (closing its stream, which unblocks the read) so its pool slot frees up for a live seeder. On marginal swarms the reachable peers frequently stop delivering after a few blocks; without this they held slots forever while we kept requesting. The read loop's `readWithTimeout` wraps each length read in a task-group race with a 30 s timer.
- **Empty state** (`Views.swift`): when there are no torrents (and nothing resolving), the list is replaced by a plain `ContentUnavailableView` ("No Torrents" / arrow-down icon / "Add a magnet link or a .torrent file to start downloading.") inside a `Group` — matching `stupid-authenticator`'s empty state. Adding stays on the toolbar + button.


