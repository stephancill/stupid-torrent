# Implementation notes — stupid-torrent-client

Running implementation log. Update **before every commit** with a concise entry describing what changed and why. Reference the relevant phase in `docs/planning.md`.

## Unreleased

### 2026-08-10 — Fix: latest target wins across repeated in-progress MKV seeks

Native AVKit scrubbing emits several `AVPlayer.seek` calls while the thumb moves. A newer call could arrive while an earlier far seek was still loading its Cues-selected cluster; the old preparation could then replace the player item after the newer seek, and because the first far seek had paused playback, a replacement seek also lost the original playing state. After that fix, a completed first seek followed by a second seek still failed: AVFoundation's estimated duration for the first partial segment could contain the second movie-time target, so the player treated it as a local seek and made that sequential transmux source walk through the unavailable intervening MKV instead of jumping via Cues. The fresh segment also exposed its rebased local clock to AVKit, resetting the native progress bar to zero even though the correct target frame was playing. Separately, every stream jump remained in `PiecePicker.priority`, so sequential seeks downloaded obsolete target windows before the latest target.

- `TorrentSeekingPlayer` now assigns every seek a generation, cancels pending preparation before handling the new target, and rejects stale work after every suspension and completion callback. Every partial-MKV user seek prepares a fresh Cues-based segment; estimated segment duration is no longer used to absorb later movie-time seeks. The player keeps the pending playhead on the newest target and carries the original resume intent through replacement seeks.
- Segmented MKV playback now uses app-owned SwiftUI controls over an `AVPlayerViewController` with its item-based controls hidden. The slider reads `TorrentSeekingPlayer`'s global movie clock and emits one seek when scrubbing ends, while AVFoundation keeps the replacement item's decode clock local. Non-segmented media retains native AVKit controls. A proposed fMP4 `edts`/`elst` mapping was rejected after simulator playback jumped from `1:15` to `10:06` in five seconds when AVFoundation reapplied the edit during the paused-to-playing transition.
- `PiecePicker.replacePriorities` and `Torrent.streamPriority` replace prior stream windows for each jump while preserving additive low-priority lookahead during ordinary sequential playback.
- Regressions cover a second far seek superseding a delayed first seek, a completed first seek followed by a second seek, playback resumption, and replacement of old picker windows. All 71 tests pass; `xtool dev build` passes. The updated app was installed over the active iOS 26.3 simulator download: the first custom seek landed at 22% and advanced from `23:52` to `24:04`; the second landed at 67% and advanced to `1:12:15` without resetting.
- `docs/handover-native-avplayer-mkv.md` records the direct-Matroska limitation, current transmux/segmented-seek architecture, native-controls clock conflict, rejected approaches, simulator evidence, acceptance criteria, and possible stable-global-asset/HLS research paths.

### 2026-08-10 — Fix: Cues-based far seeking for partial MKVs

The declared-duration `AVPlayerItem` fixed the native timeline display but not AVFoundation's internal partial-asset timeline. A native seek to 25 s while only 13.3 s of fragments were readable was clamped to exactly 13.3 s before the loader received any target-range request; the existing `farSeekServesOnceTargetVerifies` test only exercised a virtual byte offset directly and missed this player-level behavior.

- `MatroskaParser` now reads the Cues location advertised by `SeekHead` and preserves each `CueTrack` position rather than overwriting multiple track positions within a CuePoint.
- `TransmuxStreamSource.prepareForSeek` fetches the Cues element, selects the retained video track's keyframe at or before the requested time, prioritizes only that cluster, resets sequential generation at it, and returns the cluster's movie-time offset. The target segment's DTS and PTS are rebased to zero, and its virtual length/range estimates are relative to the target cluster rather than the original file start.
- `TorrentSeekingPlayer` intercepts all public `AVPlayer.seek` overloads used by native AVKit controls. A far seek pauses the old segment while preserving the requested playhead during target-piece buffering, prepares an isolated transmux source and uniquely-identified asset, waits for that exact asset to become playable, replaces the current item, translates movie time to segment-local time for AVFoundation, and resumes playback if it was playing. The player adds the cue offset only when reporting `currentTime()`; the item clock remains local so AVFoundation's decoder does not see global timestamps.
- Far seeking is capability-gated: a partial MKV without Cues uses a normal player item and its raw readable-fragment duration, so the native scrubber cannot select unavailable movie regions. Once the file is complete, its precomputed layout enables full seeking even without Cues.
- Playback all-to-end responses remain open until cancellation, the current verification frontier, or actual EOF, and briefly suspend after each 4 MiB so AVFoundation can consume and cancel them instead of the remuxer monopolizing generation of a complete multi-gigabyte file. Loader tasks are tracked and cancelled with their AVFoundation requests so an obsolete item cannot continue reading a reset source.
- Audio tracks use their sample-rate timescale, and laced AAC frames without an explicit Matroska duration receive AAC's exact 1024-sample duration. This avoids zero-duration audio samples that macOS tolerated but iOS could reject.

Player-level regression `farSeekThroughPlayerRequestsTarget` starts with only the 300 KiB head verified, reveals Cues and target-onward bytes only when prioritized, preserves the pending 25.0 s playhead, and lands there without verifying the intervening range. It also verifies that parsed Cues include the retained video track. `cuesLessPartialSourceDisablesFarSeeking` verifies that a Cues-less partial source disables far seeking while its complete equivalent remains seekable. Real MTP harness: playback advanced from 5.3 s, sought to 5000 s, resumed at 5000.7 s, and continued to 5009.0 s (`SEEK OK`, declared duration still 6459.2 s). Native simulator playback previously stopped at 1.03 s because the 4 MiB all-to-end cap falsely completed the playback request; paced playback responses then played continuously past 34 s. Full suite green; `xtool dev build` green; installed and launched on the iOS 26.3 simulator.

### 2026-08-10 — Fix: prevent overlapping MKV audio tracks

The MTP MKV has three AAC tracks: the default 5.1 movie mix and two non-default stereo commentary tracks. `MKVRemuxer` previously emitted every supported audio track as an independently enabled MP4 track without an alternate group, so AVFoundation mixed all three during playback. The remuxer now carries one enabled, supported track per media type, preferring Matroska's `FlagDefault` track and otherwise the first eligible track. This intentionally omits alternate audio tracks because the app does not yet provide an audio-track selector.

Added `selectsOnlyDefaultAudioTrack`, covering disabled/default/non-default selection. The real MTP `stream-test` now reports `audioTracks=1` while retaining the six-channel default selected by the parser. Full suite: 66 tests green; `xtool dev build` green.

### 2026-08-10 — Fix: prompt partial-MKV startup with the declared movie duration

AVFoundation derives fragmented-MP4 duration from the fragments it can currently read, so a partial MKV's raw `AVAsset.duration` only covers the downloaded prefix and its all-to-end duration probe previously waited at the verification frontier. Header mechanisms (`mehd`, nonzero track durations, and `sidx`) do not change that behavior.

- MKV/MKA all-to-end loader requests now finish after serving the current readable frontier, allowing AVFoundation to complete its probe and re-request data later. Raw MP4 behavior is unchanged, and bounded far-seek requests still wait for their target bytes.
- `TorrentStreamSession.makePlayerItem()` reads the duration already declared in the Matroska head and returns an `AVPlayerItem` that exposes it to native player controls. The app and `stream-play` now use this item, so the timeline shows the full movie duration even while the asset itself only sees the verified prefix.
- Complete-file layout and `sidx` calculations now exclude dropped tracks. The MTP file contains subtitle-only clusters; advertising those as fMP4 fragments caused generation to return empty bytes and trapped the loader at the first such cluster. Empty source reads are also rejected defensively.
- The disproven experimental `mehd` changes were removed. The CLI `stream-test` now prints raw asset and player-item durations separately.

Verified with the loader-path `long30.mkv` regression: the partial duration probe completes in about 0.5 s (asserted below 2 s), reports readable media, and the player item reports the declared 30.023 s while `farSeekServesOnceTargetVerifies` remains green. The real MTP harness reports `PLAYER ITEM: duration=6459.1967s`; its dual-torrent raw asset duration remains unstable (`37.871s` in the final run), so it is not used for player UI. Full suite remains green; `xtool dev build` green.

### 2026-08-10 — Feat: group each torrent's files in its own directory under Downloads

Each torrent's data now lives in `Documents/downloads/<display name> <8-char hash prefix>/` instead of being written flat into `Documents/downloads/` (multi-file torrents were previously only grouped by their internal `file.pathString` structure, so two torrents sharing a filename collided). `TorrentStore` gained `torrentDirectory(for:)` (sanitized display name + hash prefix for uniqueness); `add(metainfo:)` passes it to `Torrent(directory:)` and `Storage.loadVerifiedCount`, and `remove(_:)` deletes the whole per-torrent directory (data + `.verified` sidecar) instead of reconstructing file URLs. The engine needed no changes — `Storage` already scopes files and the resume sidecar under its `directory` (`Storage.swift:26,116`). Note: existing downloads at the old flat layout are not migrated (early-stage dev app; they will just re-download).



A seek beyond the downloaded frontier of a partial MKV answered the loader's bounded request with nothing and AVPlayer reverted to the buffered position, even as the seek target's pieces downloaded. Two changes:

1. **`TorrentStreamSession` loader**: bounded (seek / read-ahead) requests now **wait** for their bytes (poll like all-to-end, finishing at source EOF) instead of finishing empty — so a far seek's range is served the moment it verifies, and AVPlayer resumes at the target.
2. **`TransmuxStreamSource.prioritize`**: ranges beyond the generated layout now jump-prioritize the estimated MKV position (`firstClusterOffset + (virtual − initSize)`, since the virtual file ≈ MKV after the init) rather than the sequential frontier — so the seek target downloads ahead of playback order.

Verified on a 30 s MKV with a throttled seeder: partial download (5/11), `stream-play --seek-to 25` — the playhead resumes at 25.0 s and plays to 29.9 s once the region downloads (previously stuck at the 13.3 s frontier). New hermetic test `farSeekServesOnceTargetVerifies`: a far target reads as unavailable until its bytes verify, then serves the exact reference bytes. 63 tests green.

### 2026-08-09 — Feat: sidx-based precise seeking for complete MKVs

Complete (fully-verified) MKVs now get exact seeking: when the whole file is verified, a structural scan of the cluster headers sizes every fragment (no payload retention), the init segment carries a `sidx`, and the transmuxer serves direct jumps from the precomputed layout (exact content length, byte-range serving, prioritization). Partial files keep the sequential streaming path (no sidx — future fragments are unknown).

- `MatroskaParser.scanClusterLayout` (public) — parses a cluster's block headers + frame sizes into per-track sample counts and mdat size, without materializing sample data.
- `MKVRemuxer.fragmentSize`/`fragmentDuration`/`sidxReferences(mkvBytes:)`/`initSegment(withSidx:)` (public) — deterministic fragment sizing (every trun now carries composition offsets, so moof size is a pure function of sample count) and sidx emission.
- `TransmuxStreamSource` — complete-file mode builds the layout once at head parse (only when the whole MKV is verified), computes fragment virtual offsets against the final init (ftyp+moov+sidx), and serves direct jumps via a bounded fragment cache; `fileLength`/`reachesEOF`/`prioritize` use the layout. Streaming mode unchanged.

Fixed a latent streaming bug surfaced while testing: `readClusterRange` clamped a cluster's `elementEnd` to the read window, so a cluster larger than the window looked "complete", `parseCluster` failed on truncated bytes, and the cursor skipped past the real cluster boundary (generation stalled ~1 fragment before the frontier). It now reports the true `elementEnd` so callers grow their window / wait for verification.

Verified hermetically (virtual file == reference remux, with and without sidx; sequential streaming as bytes verify; exact content length) and on a **VBR** 30 s MKV (2 s high-bitrate + 28 s black, where content-length interpolation would land wrong): `stream-play --seek-to 25` lands at 25.8 s and plays to 30 s (`SEEK OK`). 63 tests green.

### 2026-08-09 — Fix: correct MKV playback duration/timeline through the loader

In-app MKV playback stalled at ~8.3 s (AVAsset reported `duration=8.333s` for a 30 s file, capping playback and seeks). Three interacting bugs, found by bisecting the loader-path duration against ffmpeg's own `-movflags frag_keyframe+empty_moov` output:

1. **`TransmuxStreamSource.fileLength` returned just the 128 KB margin** when the head hadn't been parsed yet (`mkvLength` was still 0). The loader used it for `contentLength` *and* as the all-to-end serve bound, so AVAsset saw a 128 KB file (~8.3 s). `fileLength` now ensures the head is parsed first, so `contentLength = mkvLength + margin`.
2. **The loader capped all-to-end requests at `requestedLength`** (AVPlayer's initial 128 KB buffer hint). Changed to serve unbounded (the hint is not a bound); the request now finishes at `reachesEOF`/file end.
3. **Coarse per-track timescale (1000) made AVAsset mis-estimate duration.** Video now uses a standard 16000 timescale (timestamps ×16, exact since 16000 = 1000·16), audio keeps the MKV tick scale; `mvhd` uses 1000 regardless. With the file-based path this alone fixed duration; all three together fixed the loader path.

Verified: `stream-test` reports `ASSET: duration=30.0s playable=true` (complete download), seeks to 20 s land and resume on a 30 s MKV, and — decisively — the **iOS app plays the transmuxed MKV through native AVPlayer** on the simulator (screenshots 5 s apart differ by 28.95%, i.e. the testsrc pattern is rendering). 63 tests green.

### 2026-08-09 — Feat: rip out VLCKit, route MKV to AVPlayer (Gates 5)

VLCKit is gone. `.mkv`/`.mka` now play through native AVPlayer via the transmuxer (`PlaybackKind.vlc` removed; mkv/mka → `.avPlayer`; `Views.swift` routes every streamable file to `PlayerView`). Deleted: `Sources/VLCBridge/` (MKVPlayerView, MKVStreamSession), `Sources/Streaming/TorrentSeekableInputStream.swift`, `Sources/Streaming/TorrentHTTPServer.swift`, their tests, the `MobileVLCKit` binary target + `VLCBridge` target + linker settings in `Package.swift`, and the gitignored `Vendor/` framework. The iOS app now builds at **3.3 MB** (was 225+ MB) with no embedded framework, and launches in the iOS 26.3 simulator. `docs/mkv-streaming.md` marked superseded; `docs/planning.md` and `docs/mkv-avplayer-transmuxer.md` updated. 63 tests green (removed the VLC-specific suite).

### 2026-08-09 — Feat: stream MKV through AVPlayer via the transmuxer (loader integration)

The transmuxer now drives real `.mkv` playback: `TorrentStreamSession` routes Matroska files to a new `TransmuxStreamSource` (a `TorrentStreamSource` presenting the virtual fragmented MP4) and serves it through the existing `AVAssetResourceLoaderDelegate`, so MKV playback uses the same AVPlayer/PiP path as MP4.

- `StreamDataSource.swift` — `TorrentStreamSource` gained `reachesEOF(fileIndex:offset:)`; the loader finishes all-to-end requests when the source is exhausted (the transmuxer's virtual length is an estimate, so EOF can't come from the byte count).
- `TransmuxStreamSource.swift` (new, actor) — parses the MKV head from a growing verified prefix (clamped to the real file length), builds the init segment + `MKVRemuxer`, then generates one fMP4 fragment per MKV cluster on demand from verified bytes. Fragment reads are sized to the verified run (a window must never extend past the download frontier — this was the "5s startup / never generates the next fragment" bug). `reachesEOF` = the whole MKV has been consumed. Content length = MKV size + 128 KB headroom (a 2 MB margin had inflated AVPlayer's buffer heuristics and produced a wrong duration).
- `TorrentStreamSession.swift` — `TorrentResourceLoaderDelegate` now takes a `TorrentStreamSource` (the MP4 path uses `TorrentStreamSourceAdapter`); the all-to-end loop breaks on `source.reachesEOF`.
- `Torrent.swift` — MSE/PE (BEP 10) handshake now retries plaintext on TCP when the encrypted attempt fails. Plaintext-only peers (aria2) close the connection after the crypto preamble rather than sending a plaintext handshake, so the in-session fallback never fired — outbound TCP never reached such peers. This is why the hermetic aria2 seeding broke after MSE landed.
- `torrent-cli` — `stream-test`/`stream-play` select MKV/MKA files (`playbackKind != .none`).

Hermetic proof (throttled aria2 seeder, 656 KB / 30 s MKV, `--seed-until 300000` → 5/11 pieces): `stream-test` reports `ASSET: duration=30.0s playable=true`; `stream-play` starts ~1 s and advances 1 s/s through the transmuxed stream. Playback stalls at the downloaded frontier only when the parallel download stalls — reproduced identically on the MP4 path (pre-existing dual-torrent + throttled-seeder harness flakiness, unrelated to the transmuxer). 79 tests green, including new `TransmuxStreamSourceTests` (virtual file == full remux, progressive streaming as bytes verify, exact seek within the generated region).

### 2026-08-09 — Feat: MKV → fMP4 transmuxer core (Gates 0-2: EBML, init segment, fragments)

First working slice of the Matroska → fragmented-MP4 transmuxer (the AVPlayer-native MKV path in `docs/mkv-avplayer-transmuxer.md`, replacing VLCKit). Pure Foundation in `Streaming`; no VLC. Hermetic gate: all five ffmpeg MKV fixtures (H.264+AAC, H.264+B-frames, HEVC Main 10, E-AC-3 5.1, AC-3) remux to fragmented MP4s that **AVFoundation loads and decodes on the macOS host** (`AVAsset.isPlayable`, correct ~3s duration, `AVAssetReader` pulls video + audio samples for every fixture).

New files in `Sources/Streaming/`:
- `EBML.swift` — EBML primitives over `Data`: VINT/size/ID parsing, element headers, ints/floats/strings. Key subtlety: element IDs carry the VINT marker bit (unlike size fields).
- `MatroskaReader.swift` — `MatroskaParser`: head parse (EBML header, Segment, Info → timestampScale/duration, Tracks → codec/codecPrivate/DefaultDuration/params, Cues), cluster + SimpleBlock/Block/BlockGroup parsing, lacing expansion (Xiph/fixed/EBML), and `readClusterRange` for incremental iteration. `MKVBlock` timestamps are confirmed **presentation** times stored in decode order (verified against ffprobe on the B-frame fixture).
- `MP4Muxer.swift` + `MP4Muxer+Fragments.swift` — ISO-BMFF writer: ftyp/moov (mvhd/tkhd/mdhd/hdlr/minf/stbl/stsd + mvex/trex), sample entries avc1/hvc1 (CodecPrivate copied verbatim as avcC/hvcC — it *is* the record, per spec), mp4a (esds wrapping the AudioSpecificConfig), ec-3/ac-3 (dec3/dac3 built from the E-AC-3/AC-3 syncframe header), moof/mfhd/tfhd/tfdt/trun + mdat, and a `sidx` builder for later seek support.
- `Transmuxer.swift` — `MKVRemuxer`: converts clusters to samples (DTS = running sum; composition offsets = PTS − DTS), one fragment per cluster, audio frames forced to sync. B-frame tracks use DefaultDuration for a monotonic DTS (composition offsets preserve exact PTS); audio and no-B-frame video use exact PTS deltas (no DefaultDuration → first-sample-duration bug fixed this way).

Fixes that `ffprobe` + AVAsset bisection (swapping boxes against ffmpeg's own `-movflags frag_keyframe+empty_moov+default_base_moof` output) surfaced:
- EBML element IDs include the marker bit (my VINT reader was stripping it → `not a Matroska`).
- `dref` is a FullBox (was missing version+flags) and its `url ` entry must be *inside* dref, not a sibling (this was the "0 tracks" / not-playable bug).
- `esds` was double-wrapped; audio sample entry was missing 4 bytes (version+revision+vendor); `stsz` was missing its sample_count field; `tkhd` flags were written as a data field, shifting the box.
- mvhd/tkhd/mdhd durations must be 0 for fragmented files (AVFoundation sums them with the fragment duration → doubled playback length).

Reference implementations cloned into `third-party/` (gitignored): `Vanilagy/mediabunny` (MKV demux + fMP4 mux, primary), `webmproject/libwebm` (EBML), `shaka-project/shaka-packager` (sparse: webm demux + mp4 mux), `DolbyLaboratories/dlb_mp4base` (dec3/dac3 layouts). Empirically verified 2026-08-09 (see `docs/mkv-avplayer-transmuxer.md` Verification log): AVFoundation decodes E-AC-3/AC-3 in ISO-BMFF on macOS + iOS 26.3 sim, and AVC/HEVC/AAC CodecPrivate is the config record verbatim.

Next: wire the transmuxer into `TorrentStreamSession` so `.mkv` streams through AVPlayer (virtual-fMP4 byte-range serving), then seeking (sidx), live/partial, app routing, and VLCKit removal.

### 2026-08-09 — Feat: prefill magnet link from clipboard when the add sheet opens

Opening the "Add torrent" sheet now reads the pasteboard and, if it parses as a valid magnet link via `MagnetLinkParser.parse`, prefills the magnet field so the user can tap Add directly. A new `clipboardString()` helper wraps `UIPasteboard`/`NSPasteboard` behind the platform `#if`, mirroring the existing `copyMagnet()` pattern. Non-magnet clipboard contents are ignored and the field stays empty.

### 2026-08-09 — Fix: keep loopback HTTP socket I/O off Swift's cooperative executor

Opening the partially-downloaded Backrooms MKV failed immediately with VLC's `Could not open http://127.0.0.1:...: Unknown error`, while the completed smoke fixture played. The same issue made all eight parallel `TorrentHTTPServerTests` hang: blocking BSD `accept()`, `read()`, and `write()` calls ran directly in unstructured Swift tasks, so active torrent peers or concurrent server tests could exhaust the cooperative executor before the loopback server responded. `TorrentHTTPServer` now bridges blocking socket operations through GCD-backed checked continuations. The HTTP tests remain parallel and complete, exercising the production concurrency behavior rather than hiding it by serializing the suite.

Directly probing the live Backrooms server exposed a second large-file-only issue: an un-ranged `HEAD` request incorrectly took the 2 MB initial-GET lookahead path, returning `206` and a 2 MB `Content-Length` instead of the real 4.78 GB size. The lookahead response is now GET-only; HEAD always reports `200` with the full length. The HEAD test now uses a synthetic 4.78 GB declared length so this cannot regress behind the prior 200 KB fixture.

The HTTP framing was also corrected on both sides of the tests: request headers are now read through the full `\r\n\r\n` delimiter instead of stopping after any CRLF, and the test client preserves response-body bytes received in the same read as the headers. Previously fragmented Range headers could be ignored by the server, while coalesced response bytes made the client wait forever for bytes it had already discarded.

VLCKit debug logging then showed the live Backrooms stream being detected as corrupt MPEG-PS (`mpg123`/`mpeg2video`, repeated `garbage at input`) instead of Matroska. A direct range read confirmed byte zero was all zeros even though the resume sidecar marked piece 0 verified; this was the known stale sidecar left after the sparse file had previously been deleted/recreated. Streaming now SHA-1 revalidates each verified piece lazily before serving it for the first time in a process. A mismatch clears and immediately persists the verified bit, requeues the piece at jump priority, and withholds corrupt bytes until a valid piece is downloaded. If the torrent had been considered complete and its run loop already exited, invalidation restarts it so the stale piece can actually be repaired.

The status now stays honest too: `Torrent.run()` re-verifies the pieces the resume sidecar marked verified before trusting them. A "complete" torrent whose data file was deleted/recreated (sparse at full size, so a size check can't catch it) has its stale bits cleared at startup and falls back into downloading — the detail view shows the real progress instead of "Complete", and the corrupt bytes are repaired before they can reach a player. Partial torrents re-verify restored pieces in the background for the same reason. The race where an invalidation landed during a previous `run()`'s teardown and the restart was swallowed is fixed by `ensureStreamingRepair()`, which waits for the teardown to finish before starting a fresh run.

`MKVStreamSession` now surfaces the torrent's verified fraction (`downloadProgress`), and the player shows "Buffering — N% downloaded" while VLC is stalled on a still-downloading or repairing file, instead of an endless bare spinner. Verified on the simulator: the repaired Backrooms file plays and shows the buffering percentage during the final repair pass; a fully-verified MKV plays with controls, no spinner.

Opening a player for a *downloading* torrent could show a blank full-screen cover with no controls: `TorrentDetailView` is presented via `navigationDestination(for: TorrentItem.self)`, and `TorrentItem` is `@Observable`, so every 1 s status tick recreated the detail view and reset its `@State` — the cover then presented with `activeKind`/`activeFileIndex` nil (a fresh `openPlayer` set them, but a re-init wiped them before the cover content built; a complete torrent like media.mkv never re-inited, which is why it worked). Player presentation now lives on the stable `TorrentStore.pendingPlayback` (`PlaybackRequest`) and the `.fullScreenCover(item:)` is attached to `ContentView`'s navigation stack, so a recreated detail view can't break it. The `#if !os(iOS)` host build keeps its local `.sheet` presentation.

The player's `refreshState()` showed a loading spinner during normal playback: libVLC reports `.buffering` for HTTP/streaming input even while frames are rendering, and the state mapping translated that straight to the buffering UI. The mapping now treats an advancing position as the reliable "actually playing" signal (falling back to `.buffering` only when playback is requested but the position is frozen), so the spinner and Play button only appear during genuine buffering — initial load or a stall on not-yet-verified bytes — alongside the "Buffering — N% downloaded" progress text.

Seeking felt broken/laggy: the seek slider called `session.seek` (a `VLCMediaPlayer.time` set, which is a fresh HTTP range request + demux re-sync on the torrent file) on *every* drag tick, flooding VLC's input for a large MKV. The scrub now records the drag position in `scrubTarget` (so the thumb follows the finger) and issues a single seek via a 400 ms debounce after the last movement, then clears the target so the slider tracks real playback again. Verified: dragging to ~31% of a 110-minute MKV seeks there and continues playing.

### 2026-08-08 — Fix: full pipelines for peers on exhausted pieces (distinct missing blocks per peer)

Follow-up to the endgame re-request fix. The log showed 6,196 refills stuck at `requesting 1 blocks` while the download depended on one seeder (`185.21.216.198` = 37k/52k refills). Root cause: `nextBlockRequest` returned the same missing block to a peer on every refill, and `refillPipeline`'s `guard !outstanding.contains(key) else { break }` then truncated that peer's pipeline to **one** block per round-trip — peers on a near-complete piece (cursor exhausted) contributed a trickle while the single real seeder carried the swarm.

**Changes**:
- Shared `BlockKey` type (`BlockKey.swift`; was file-private in both `Torrent.swift` and `PeerSession.swift`).
- `PeerSession.outstandingKeys` exposes the peer's in-flight set; `nextBlockRequest`/`nextBlock(in:excluding:)` serve **distinct** blocks per peer — the cursor-advance path skips excluded blocks, and the missing-block scan skips both excluded and already-received blocks.
- Bounded endgame redundancy: `outstandingCounts` (per-block request count, incremented in `registerOutstanding`, decremented by the new `unregisterBlock` on receive/peer-drop/piece-complete) caps a missing block at `maxMissingRedundancy` (2) concurrent requests, so a block only a dead peer holds doesn't flood every pipeline — peers that can't help fall through to the next piece (or a fresh allocation).
- `refillPipeline` guard `break` → `continue` (the excluding set makes duplicates unreachable; the guard is now only defensive).

**Verification**: 62 tests green. Live (QxR swarm): zero `requesting 1 blocks` (all refills full 48-block pipelines), piece 194 — previously stuck >60s — verified immediately, steady ~350-730 KB/s (swarm-seeder-bound, not engine-bound).

### 2026-08-08 — Fix: "fast download but nothing verifies" (stalled pieces never re-requested)

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

### 2026-08-08 — Fix: MKV streaming via loopback HTTP server (VLC MediaKit)

MKV streaming still showed 0:00 / wouldn't play even with fully-verified data and after the SIGPIPE fix. Isolated the cause by testing VLC against a **real file path** (played perfectly: `dur=60023ms`, position advanced) vs `VLCMedia(initWithStream:)` (stalled at `dur=0`) — proving the problem was the stream API, not the engine or the codec.

**Root cause**: VLCKit's `open_cb` for `VLCMedia(initWithStream:)` reports the stream size as `UINT64_MAX` (unknown). VLC's Matroska demuxer needs a known size to build the seek table / compute duration; with an unknown-size input it reads to the prefetch EOF and stalls at 0:00 (also explains why the tiny 348 KB gate-0 `test.mkv` "worked" — it fit in one read).

**Fix** (`Streaming`): new `TorrentHTTPServer` — a loopback HTTP/1.1 server over the existing BSD sockets that serves verified bytes with a real `Content-Length`, `Accept-Ranges: bytes`, byte-range support (`206`/`Content-Range`, suffix + open-ended ranges, `416` with `Content-Range: bytes */<size>`), and keep-alive. Requested ranges are prioritized in the picker and responses block until verified (progressive serve). `MKVStreamSession` now points `VLCMedia` at `http://127.0.0.1:<port>/<file>` instead of `initWithStream`.

Key details learned while debugging:
- VLC's HTTP input seeks to exact EOF (`bytes=<size>-`) to probe size; it accepts `416`, so return `Content-Range: bytes */<size>`.
- VLC's h1conn logs `connection failed` when `Connection: close` is sent on ranged responses — keep the connection alive (no `Connection: close`; loop serving requests on the socket).
- Serving the whole file as a single 200 made VLC's prefetch hit EOF and stop; bounded the initial whole-file request to a 2 MB 206 lookahead so VLC issues range requests for the rest (mirrors the loader/stream lookahead).
- VLCMediaPlayer's `VLCMediaPlayerTimeChanged`/`StateChanged` notifications don't reliably fire in this VLCKit build — `MKVStreamSession` now polls the player (250 ms) for position/duration/state instead of relying on notifications.

**Verification**: `TorrentHTTPServerTests` (8) — HEAD length, full 200, 206 byte-range, open-ended, suffix, 416, progressive-serve, prioritize-follows-client. Simulator smoke test: `http://127.0.0.1` server, VLC parsed the MKV (`Duration=60023`), started h264/aac decoders, `Received first picture`, and **position advanced** 89 ms → 11325 ms over 12 s (polled from the player). A follow-up visual check on the iOS 26.3 simulator confirmed that the rendered test pattern and timeline advance on screen; screenshots six seconds apart changed 31,029 pixels. The earlier static screenshots did not indicate a VLC drawable failure.

### 2026-08-08 — Fix: app crashed with SIGPIPE during streaming + active download

The MKV player crashed while waiting to stream a partially-downloaded file (Backrooms QxR `749c6111…`): the app died ~100 s after opening the player. Simulator repro (auto-open the player on the partial torrent) reproduced it — `launchd_sim` reported `exited due to SIGPIPE | sent by stupid_torrent_client`.

**Root cause**: the engine's BSD sockets (`BSD.swift`) never suppress SIGPIPE. When a peer disconnects mid-download and an in-flight `write()`/`send()` lands on the closed socket, Darwin raises SIGPIPE, which by default terminates the process. The engine already throws `SocketError.write(errno)` on EPIPE (peer dropped) — the missing piece was suppressing the signal so the write returns EPIPE instead of killing the app. It surfaced now because streaming keeps the download (and its writes to flaky swarm peers) running under the player.

**Fix** (`BSD.swift`): `BSD.setNoSigPipe(fd)` sets `SO_NOSIGPIPE`, applied at every socket creation point — `TCPSocket.init()`, `TCPSocket.init(fd:)` (covers inbound accepted sockets via `PeerStream`), and `UDPSocket.init()`. With it, writes to a closed peer return EPIPE and the existing peer-drop handling applies.

**Verification**: new `NoSigPipeTests.writeToClosedPeerThrowsInsteadOfSigPipe` — writes to a socket whose peer closed repeatedly until the RST surfaces; asserts a throw. **Without** `setNoSigPipe` this test kills the test runner (output truncates exactly where SIGPIPE fires) — confirming it reproduces the crash; with the fix it passes. Full suite 63 tests green. The app then ran 180 s in the simulator with the QxR player open and no crash (the swarm had dried up, so the write path wasn't heavily exercised there — the hermetic test is the deterministic gate). Deployed to the iPhone; launch there waits for the phone to be unlocked.



Backrooms QxR (`749c6111…`, 8 MiB pieces, 571 pieces, single 4.78 GB mkv) in the simulator downloaded at several MB/s (file grew) while verified stuck at ~1 piece — every piece that did verify had first logged a **20 s stall + requeue**. Root cause vs the log:

- `pieceBlockCursor` allocates a piece's blocks once, to whichever peers refill first. When the cursor exhausts (all 512 blocks handed out) but the peers holding the tail blocks never deliver them, `nextBlock(in:)` returned `nil` — the missing blocks were **never re-requested** until the 20 s stall timer (or a peer drop) reset the cursor. On a churny swarm every piece paid a dead 20 s wait, so the data rate (~7 MB/s at peak) never became verified pieces (~1 per 40-60 s).
- The 8 MiB piece length made this severe: 512 blocks per piece meant many peers' pipelines could exhaust a piece's allocation while the tail sat undelivered.

**Fix** (`Torrent.nextBlock(in:)`): when a piece's cursor is exhausted but it still has missing blocks, return the *next missing block* (endgame-style, mirroring webtorrent's duplicate tail requests) instead of `nil`, so a near-complete piece finishes in one round-trip. `PeerSession.refillPipeline` gained a guard to skip a block already in that peer's outstanding set (otherwise `nextBlockRequest` keeps returning the same missing block and the fill loop spins forever).

**Verification**: 62 tests green. Redeployed to the simulator: with the fix, zero `stalled` lines and pieces verify continuously (`piece 71…74` ~15 s apart at the swarm's ~530 KB/s — verification now tracks the real delivery rate instead of losing 20 s per piece). Note the sidecar's stale low pieces (bits set from a prior deleted file) still produce sparse/zero data at the file head; a full verify/resume from a clean bitfield is unaffected.

### 2026-08-08 — MKV streaming via embedded MobileVLCKit (iOS-only)

The documented mkv limitation (implementation-notes line 423) is now closed for MKV/MKA: Matroska files stream through VLCKit instead of AVPlayer. Full detail in `docs/mkv-streaming.md`; this entry records what landed and why.

**Decision**: embed **MobileVLCKit 3.7.2** (LGPL, static XCFramework in gitignored `Vendor/`, 225 MB after stripping dSYMs) for MKV playback rather than writing a Matroska demux + fMP4 remux from scratch. VLCKit accepts the motivating file directly (HEVC Main 10 + E-AC-3 Atmos + embedded SRT). Tradeoffs accepted: app size, LGPL attribution, custom player controls (no AVPlayerViewController/PiP for MKV). macOS never links it — the platform-conditional dependency keeps `swift build`/`swift test`/`torrent-cli` VLC-free.

**Packaging (gate 0, passed)**:
- `Package.swift`: `.binaryTarget(name: "MobileVLCKit", path: "Vendor/MobileVLCKit.xcframework")` + new `VLCBridge` target (iOS-only dep on the binary; declares the podspec system frameworks/libraries: QuartzCore/CoreText/AVFoundation/Security/CFNetwork/AudioToolbox/OpenGLES/CoreGraphics/VideoToolbox/CoreMedia + c++/xml2/z/bz2/iconv). `stupid_torrent_client` depends on `VLCBridge` only under `.when(platforms: [.iOS])`.
- xtool simulator build embeds `MobileVLCKit.framework` into `App.app/Frameworks` and links via `@rpath`; app launches with the framework loaded. macOS host `swift build`/`swift test` unaffected.
- Repack step: official VideoLAN CocoaPods tarball (`MobileVLCKit-3.7.2-…tar.xz`), extract the `.xcframework` + `COPYING.txt` into `Vendor/`, delete `dSYMs/`. `Vendor/` is gitignored; a setup step must repopulate it.

**Stream plumbing (`Streaming`)**:
- New `TorrentStreamSource` protocol (fileLength/availability/read/prioritize) + `TorrentStreamSourceAdapter` forwarding to the `Torrent` actor's streaming APIs.
- New `TorrentSeekableInputStream`: an `NSInputStream` for libVLC's callback bridge (`VLCMedia.initWithStream`). Reads **block until verified bytes exist** (a premature 0 would look like EOF to libVLC); seeks via `NSStreamFileCurrentOffsetKey`; a background feed task pulls verified bytes into a capped 2 MB buffer, prioritizing a 2 MB lookahead window per read (the picker's jump classification handles seek targets automatically).
- Swift 6 concurrency notes: `NSCondition` lock/unlock is banned in async contexts, so locked sections live in sync helper methods; and `Task { await self.… }` from an `InputStream` subclass trips the sending check (the `Stream` base isn't Sendable), so all mutable state lives in a separate `@unchecked Sendable` box (`TorrentStreamBuffer`) the feed task captures instead of the stream itself. Two real bugs found by the tests: the feed loop used the consumer's cursor as its fetch cursor (re-appending the same range → unbounded buffer), and it broke at `fetchOffset >= fileLength` even before the consumer drained (a backward seek then starved). Fixed with a dedicated fetch cursor (`fileOffset + buffer.count`) and an EOF condition gated on the consumer actually reaching the end.

**VLCBridge (iOS-only target)**:
- `MKVStreamSession` (@MainActor @ObservableObject): owns the stream + `VLCMedia` + `VLCMediaPlayer`; applies a tail-jump priority (Cues index, analogous to moov-tail) at init; exposes state/duration/position/seekable + audio/subtitle track lists; `attach(drawable:)`, `seek(toMs:)`, `selectAudioTrack`/`selectSubtitleTrack`, `teardown()` (stops player + closes stream).
- `MKVPlayerView`: SwiftUI fullscreen player with a plain-`UIView` drawable, black background, loading/failed states, play/pause + seek slider, and audio/subtitle pickers. Reuses the existing `.playback`/`.moviePlayback` audio session.

**App routing (`TorrentCore` + `Views.swift`)**:
- `Torrent.playbackKind(forFileNamed:)` — `.avPlayer` (existing whitelist), `.vlc` (mkv/mka), `.none` — drives the file rows and the player dispatch. `.vlc` rows open `MKVPlayerView` via the existing `.fullScreenCover`; on macOS `.vlc` is treated as `.none` (no VLCKit). `contentType(forFileNamed:)` unchanged for the AVPlayer loader.

**Verification**:
- 8 new `SeekableInputStreamTests` against a fake source; 61 tests green (macOS host).
- Gate-0 render test (temporary env-gated smoke path, removed after passing): generated 10 s H.264/AAC MKV played fully — stream served the whole file, VLC `playing=true seekable=true`, test pattern frames advanced between screenshots.
- Real Backrooms MKV: HEVC Main 10 + E-AC-3 + SRT decodes and renders (screenshots show real video content); playback paces to the download — with 0 live peers it buffers rather than erroring.
- iOS simulator build embeds the framework; `strings` on the final app binary shows no leftover smoke code.

**Known limitations / follow-ups**: MKV PiP (VLCKit has no native PiP API), webm/avi/AV1-in-MKV still unplayable, seeks beyond the downloaded frontier wait for the jump range to verify. LGPL obligations: `Vendor/COPYING.txt` shipped, end-user attribution still to add to the About/acknowledgements UI before release.

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

### 2026-08-07 — Handle `magnet://` deep links

Safari offered to open the app for magnet links (the `magnet` URL scheme was registered in Info.plist) but nothing happened — there was no `onOpenURL` handler, so the URL was dropped. **Fix** (`Views.swift`): `.onOpenURL` calls `store.addMagnet(url.absoluteString)` for `magnet`-scheme URLs, mirroring `stupid-authenticator`'s `importOTPAUTH`. Verified on the simulator with `simctl openurl "magnet:?xt=urn:btih:c9e15763..."` — the app immediately started `bootstrap: querying DHT for peers`.

### 2026-08-07 — Copy Magnet action in torrent details

`TorrentDetailView` gained an "Actions" section below Files with a **Copy Magnet** button that writes the full magnet link (`magnet:?xt=urn:btih:…&dn=…&tr=…`, built from `Metainfo` via a new `magnetLink(_:)` helper in `Views.swift`) to the pasteboard (iOS `UIPasteboard`, macOS `NSPasteboard`) with a brief "Copied ✓" label state.

### 2026-08-08 — Magnet resolution + download fixes for QxR live swarm (Backrooms 2026)

The app failed to resolve the Backrooms magnet (webTorrent: ~1.6 s; ours: never within 120 s+) and, when the `.torrent` was used directly, downloaded at 800 KB/s but **stalled at 0 pieces forever** (pieces 3+ never verified even at 262 MB). Both root-caused against `third-party/webtorrent`.

**Metadata resolution (3 bugs):**
1. **Tracker announce was gated behind the DHT sweep.** `MagnetBootstrapper.metainfoAndPeer` swept the 314-peer DHT result (concurrency 12, up to ~12 s/peer) **before** ever announcing to trackers — the round-0 tracker announce never happened in the first ~5 min. WebTorrent's `torrent-discovery` announces to trackers at t=0. **Fix**: announce to trackers immediately, sweep tracker peers first, and sweep DHT peers concurrently (task group) instead of awaiting the ~20 s DHT lookup.
2. **No `metadata_size` gate.** We requested ut_metadata piece 0 from *every* peer advertising `ut_metadata`, then waited the full 8 s fetch timeout for leechers that have no info dict. WebTorrent's `ut_metadata` reads `metadata_size` from the extended handshake and skips metadata-less peers instantly. **Fix**: `ExtendedHandshake.metadataSize` + `MetadataError.peerHasNoMetadata`; skip such peers immediately.
3. **Sequential chunk requests + long per-peer timeouts.** Now request **all** metadata pieces at once (webtorrent `_requestPieces`) and tightened timeouts (fetch 8→5 s, connect 4→3 s, sweep concurrency 12→24).

**Download (2 bugs):**
1. **Stalled pieces could never complete** (`Torrent.requeueStalledPiece`): it reset `pieceReceivedBytes` to 0 while keeping `receivedBlocks`, so already-received bytes were deduped and never re-counted → `receivedBytes` could never reach `pieceLength`, so a piece stalled at e.g. 500/512 blocks verified-loop forever. **Fix**: keep the byte counter across a stall requeue.
2. **Stalled pieces were dropped from the picker.** `requeueStalledPiece` also called `picker.clearRequested` + removed from `activePieces`; the sequential cursor had already moved past the piece, so the last ~12 blocks were never re-requested. **Fix**: keep the piece active (cursor reset to `nextMissingOffset`) so the next peer refill immediately re-requests the missing blocks; the stall timer still bounds a truly-dead piece.
3. **Requested blocks from peers that don't have the piece.** We ignored `bitfield`/`have`/have-all/have-none entirely, so requests went to leechers that could never serve them. WebTorrent filters selection by `wire.peerPieces`. **Fix**: `PeerSession` tracks a per-peer `Bitfield` (`PeerMessageID` gained `haveAll`/`haveNone`), `nextBlockRequest`/`nextPiece(available:)` only hand out blocks the peer claims to have.

**App**: `TorrentStore.addMagnet` now uses `metainfoAndPeer` and injects the metadata-serving peer straight into the download (it's a verified-reachable seeder) instead of discarding it; `add` is async to `await torrent.addPeer`.

### 2026-08-08 — Completed torrents go fully idle (no announce/DHT/listener/seeding)

Observed in the app: on every launch, **completed** torrents (restored from their `.verified` sidecar) were still announcing to trackers, running DHT lookups, binding TCP/µTP listeners, and seeding — `Torrent.run()` started `announceLoop`/`dhtLoop`/`startListener`/`tickerTask` unconditionally, and the `while` loop only broke afterward, having already fired a `.started` announce, a DHT query, and a port bind per completed torrent.

**Fix** (`Torrent.swift`): `run()` now early-returns for torrents whose resume sidecar already marks them complete (`picker.verified.allSet`) — before starting any network machinery. It just loads the bitfield, publishes the `.seeding`/complete status, and returns. Storage is deliberately left open (streaming reads reopen file handles on demand; `stop()` closes it on removal).

**Verification**: rebuilt + redeployed to the simulator. Console shows zero `announce`/`listening`/`connecting`/`nextBlockRequest` lines for the completed BBB/Sintel torrents; only the genuinely-incomplete torrents (Backrooms 9/571, John Wilson 1/1024, Cosmos 99/843) announce/listen. 49 tests green.

**Verification (live QxR swarm):** metadata resolves in ~40 s worst case (previously never within 120 s; swarm-quality dependent — webTorrent's 1.6 s run had a lucky first-peer). Download: pieces now verify through stall/requeue cycles — one run verified 13 pieces (0-8 within 90 s) at up to 1.4 MB/s; the remaining `bad`/`missing` pieces at `--stop-at` are the documented overshoot (mid-flight piece at stop). Full suite: 49 tests green. Deployed to the simulator; `simctl openurl` of the magnet resolved metadata and began downloading. Note the peer bitfield change means a peer that sends no bitfield/have is treated as a leecher and gets no requests — matches webtorrent.

### 2026-08-08 — Detail view: remove Upload field, Download shows /s, mkv streaming clarification

- **Upload field removed** (`Views.swift`): the Status section no longer shows `Upload` — we don't seed (completed torrents are idle), so it was always 0.
- **Download field units** (`Views.swift`): added `byteRateString` and the Download row now shows e.g. "1.4 MB/s" instead of the raw `byteString` (which is for file sizes, no `/s`).
- **Backrooms not streamable — expected**: the release is `.mkv`; `Torrent.contentType(forFileNamed:)` whitelists only AVPlayer-demuxable containers (mp4/m4v/mov/m4a/mp3/aac/wav), so mkv rows are `.disabled`. AVFoundation can't demux MKV even though the x265 stream inside is HEVC — this is the documented mkv/webm/avi limitation (QuickLook fallback; VLCKit future work).

### 2026-08-08 — Deletion fix: `.torrent` removal must match by info hash, not displayName

User reported a torrent (John Wilson S03) reappearing every launch after being deleted 3 times. Root cause: `TorrentStore.remove` deleted the persisted `.torrent` by reconstructing its filename from `item.name` (= `metainfo.displayName`), but the file on disk was saved under a *different* name. John Wilson was imported as a `.torrent` file (file `name` `...x264[eztv.re]`), then its persisted copy gained a `stupid-torrent-display-name` of `...x264[eztv.re][eztvx.to]` (the magnet `dn`). So `remove` tried to delete `...x264[eztv.re][eztvx.to].torrent` — which never existed — the `try?` swallowed the failure, and `restore()` re-added the torrent from the surviving file on every launch.

**Fix** (`TorrentStore.remove`): scan `torrentsURL` for any `.torrent` whose parsed `Metainfo.infoHash` equals the item's id and delete that — robust to displayName/name divergences. Data files + `.verified` sidecar were already deleted by info-hash-derived paths (unaffected). 49 tests green.

### 2026-08-08 — Torrent list & detail polish: ETA, fonts, section rename

- **List rows** (`Views.swift`): torrent titles are now `.body` (were `.headline`), and the trailing timestamp is `.body` (was `.caption`).
- **Section rename**: the download section header is now "In Progress" (was "Downloading").
- **ETA in the list**: in-progress rows show `ETA <1m`/`ETA 12m`/`ETA 3h`… (remaining bytes ÷ download rate) instead of the added timestamp; complete/no-status rows still show the added time.
- **ETA in the detail view**: the Status section gained a persistent `ETA` row — it always renders, showing `-` when it can't be computed (stalled/zero rate), rather than hiding.
- Refactored the remaining-time math into shared helpers `remainingSeconds(_:metainfo:)` and `durationString(_:)`, used by both the row and the detail view.
- Built + installed to the `NoFeedSocial iOS 26.3` simulator.

### 2026-08-08 — Peer pool mirrors webtorrent: drain-on-drop + reconnect backoff

Observed: the app hovered at ~0 / 16.4 / 32.8 KB/s (1-2 blocks/s) for minutes before jumping to 500+ KB/s. Root cause vs webtorrent: our pool only connected peers at announce cycles (60-90 s), and a connected peer stayed in `pendingPeerAddresses` for its whole session, so `pending + active` double-counted live connections — we held 3-5 peers where webtorrent held 18-55.

**Fix** (`Torrent.swift`) — mirrors webtorrent's `_queue` + `_drain()` + `RECONNECT_WAIT`:
- **Peer queue + drain**: `considerPeer` appends to a FIFO `peerQueue`; `drainPeerPool()` pops and dials while `pending + active < maxActivePeers`. Called on every new peer AND every `peerDisconnected` (webtorrent calls `_drain()` on `removePeer`), so freed slots refill immediately instead of waiting for the next announce.
- **Pending freed on connect**: `pendingPeerAddresses` is removed once the connection is established (before the blocking `session.run()`), so `pending + active` counts connecting + connected exactly.
- **Reconnect with backoff**: `scheduleReconnect` re-queues a dropped/failed peer after `[1s, 5s, 15s]` (`flushReconnect`), capped at 3 attempts; a peer that handshaked resets its budget (webtorrent resets `retries` on handshake). µTP→TCP fallback unchanged.
- `stop()` clears the queue/reconnect state.

**Verification** (live QxR swarm): pool now holds **20-47 peers** (was 2-5); ~766 connect attempts in 60 s (was ~96 in 90 s). Pieces verify through stall/requeue cycles (piece 0 reached 512/512 bytes after two 20 s stalls); speeds reach 500-880 KB/s. Full suite: 49 tests green.

### 2026-08-08 — Download pause/resume (engine + app, Phase 8 polish)

`TorrentStatus.State.paused` existed but was never published, and `TorrentItem.pauseResume()` was never wired to any UI. Implemented real pause/resume.

**Engine** (`Torrent.swift`):
- `pause()`: guard `isRunning && !isPaused`; set `isPaused`, tear the network down immediately via the new `stopNetwork()` (announce/DHT/ticker cancelled, TCP listener + µTP stopped, peer queue cleared, all peers disconnected), flush the `.verified` sidecar, announce `.stopped`, publish `.paused`. Storage stays open so streaming of downloaded pieces keeps working.
- `resume()`: guard `isRunning && isPaused`; clear the flag, reset `firstAnnounce` (so the tracker gets a fresh `.started`), publish.
- `run()` now **parks while paused** (250 ms sleep loop) instead of exiting, and on resume calls `startNetworkMachinery()` again (extracted from `run()`: announce loop + DHT loop + listener + ticker). A pause can interleave with a machinery start via actor reentrancy, so the park block also tears down machinery it finds already started (`if networkStarted { await stopNetwork() }`) before parking. Teardown announces are now gated on `networkStarted` so a never-started (paused-at-entry / completed) torrent doesn't announce `.stopped`.
- `publishStatus()` now emits `.paused` when `isPaused`.
- Peer-coordination guards: `considerPeer`/`drainPeerPool`/`scheduleReconnect`/`flushReconnect` no-op while paused, so in-flight sessions can't re-dial after a pause.
- `stop()` reuses `stopNetwork()` and clears `isPaused`.
- New `running` accessor (`isRunning`) and an `enableDHT` init flag (default `true`; off keeps `swift test` hermetic — the DHT loop otherwise fires real lookups).

**App**: `TorrentItem.isPaused` (from the broadcast state) + `togglePause()` (calls `torrent.pause()`/`resume()`; the status/run tasks stay alive across both). UI: leading swipe action "Pause"/"Resume" on list rows, a `pause.circle` icon + "Paused" caption on paused rows (instead of pie/ETA), and a Pause/Resume button at the top of the detail Status section.

**Tests** (`TorrentPauseResumeTests`, +2 → 51 total): `pauseAndResumeControlDownloadState` — pause/resume before run are no-ops; waits for `torrent.running`, then pause → `.paused` with 0 peers, resume → `.downloading`, pause again → `.paused` (tracker-less BBB metainfo + `enableDHT: false`, so no network beyond loopback). `pauseIsNoOpForCompleteTorrent` — a sidecar-complete torrent stays `.seeding` through pause/resume.

**Verification**: `swift test` 51 green; live `torrent-cli add Fixtures/big-buck-bunny.torrent --stop-at 2MB` confirms the refactored `run()` (machinery start, park loop, `networkStarted`-gated teardown) still downloads and verifies from the live swarm.

Note: paused state is intentionally not persisted — a relaunch resumes an in-progress torrent (the app already restores progress from the `.verified` sidecar).

### 2026-08-08 — Magnet metadata resolution: 200s → ~4s (Backrooms live swarm)

Benchmarked the Backrooms magnet (`3b124452…`) with a new `torrent-cli resolve` command (times `MagnetBootstrapper.metainfoAndPeer` only; `add` skips bootstrapping once a `.torrent` is saved). Baseline: **200.3 s**. Final: **2.9-8.4 s** (warm DHT cache), **4.1 s** cold cache. WebTorrent: ~1.6 s (lucky first-peer). Root causes vs webtorrent and fixes:

1. **Batch-then-sweep discovery → streaming pool** (`MetadataExchange.swift`). The old flow announced to ALL trackers (awaiting the slowest — a dead UDP tracker gated the sweep for its full 15 s), then drained DHT peers only after the full lookup, then swept fixed 300-peer batches. Rewrote `metainfoAndPeer` around a `PeerAccumulator` actor: trackers and DHT append peers as each response lands, and a continuous `sweepStreaming` loop drains the pool with N workers, refilling each slot the moment it frees — no announce gate, no batch boundaries, no inter-round sleeps.
2. **`connect(9)` EBADF storm — the big one.** `PeerStream.connect`/`send` ran the blocking syscall on `Task.detached` (cooperative pool). ~8 threads means 40+ concurrent connects queue; a peer's 3 s timeout task then closes the stream while a queued `connect()` is still pending, so `connect()` runs on a closed fd → EBADF. Reproduced in isolation: 40 concurrent connects = 24× EBADF + 16× timeout. Fixed by (a) running connect/send on a dedicated `Thread` (true parallelism — 40 connects now drain in 2 s, was 15 s) and (b) arming the per-fetch timeout only AFTER connect completes (connect has its own 2 s budget). This alone took the sweep from 0 peers reaching MSE to several completing handshakes.
3. **DHT lookup short-circuited at the first peer** (`DHTClient.lookup` had `if !peers.isEmpty { break }`) → sparse swarms returned 1 peer. Removed it: the full iterative closest-node search now returns 554 peers for Backrooms (was 1).
4. **DHT peer cache** (`DHTClient`): persisted live peers per infohash (`stupid-torrent-dht.peers`, mirroring bittorrent-dht's peer store). `cachedPeers(infoHash:)` emits up to 500 cached peers at t=0 before any network query — warm resolutions start from known-reachable peers. Also added cancellation checks so `dhtTask.cancel()` takes effect promptly.
5. **Per-fetch timeouts tightened** to match webtorrent's cycle speed: connect 3 s→2 s, metadata fetch 5 s→3 s, sweep concurrency 24→48, retry-once only for `PeerStreamError.closed` (a timed-out peer stays dead). UDP tracker receive timeout 15 s→5 s (a packet-dropping tracker no longer stalls every round).

`PeerStream.connect`/`send` thread change applies to the download path too (same pattern). New `torrent-cli resolve <magnet>` benchmark command kept (it's the dev harness for future regressions). 51 tests green; `add` flow verified end-to-end (metadata resolved, `.torrent` saved, known-good metadata peer injected into the download).

### 2026-08-08 — Known-good peer cache (warm-path follow-up)

Timeline tracing of a 7.6s resolve showed the first ~5s was spent draining the 500 cached `get_peers` records — which are ~99% stale/NAT'd garbage, same as tracker lists — before the fresh tracker peers hit a live seeder. Raw DHT records are not "known-reachable", so caching them wholesale just delays the lottery.

**Change** (`DHTClient.swift`): the peer cache now stores a `good` flag per peer (line format `… <port> 0|1`). `cacheKnownGood(_:for:)` marks peers that completed a real handshake / served metadata as `good`, persists them immediately, and orders them FIRST so the next resolution for that infohash retries them before the stale records. `MagnetBootstrapper` calls it with the metadata-serving peer on success. Cached good peers for Backrooms: `151.243.141.9`, `69.4.196.10`.

### 2026-08-08 — Detail view: Pause/Resume + Copy Magnet moved to toolbar kebab menu

`TorrentDetailView` (Views.swift): the Pause/Resume button (previously the first row of the Status section) and the whole "Actions" section (Copy Magnet) are replaced by a single kebab menu (`ellipsis.circle`) in the navigation bar's top-right. Pause/Resume still only appears for incomplete torrents; Copy Magnet shows its temporary "Copied" checkmark state in the menu label. Removed the now-empty Actions section. `swift build` green.

### 2026-08-08 — Fix: kebab menu "pulsing brightness" every second

The 1s ticker called `publishStatus()` unconditionally, and `StatusBroadcast.publish` always yielded — even when nothing changed. Each identical snapshot replaced `TorrentItem.status`, invalidating every SwiftUI observer, so `TorrentDetailView` rebuilt its toolbar `Menu` every tick (the visible brightness pulse).

**Fix**: `TorrentStatus` is now `Equatable`; `Torrent.publishStatus()` caches `lastPublishedStatus` and skips the publish when the snapshot is unchanged. Idle/seeding/complete torrents now emit one status and stop; active downloads still publish each second (rates/verified change, which the Status section legitimately needs).

**Verification**: 53 tests green (incl. `pauseAndResumeControlDownloadState`, which exercises repeated `publishStatus` calls). Deployed to the simulator.

### 2026-08-08 — Fix (round 2): kebab menu pulse for active downloads

The dedupe fix above stopped publishing identical snapshots, but an **actively downloading** torrent still changes every tick (rates/verified), so `TorrentDetailView.body` kept re-evaluating each second and SwiftUI rebuilt the toolbar `Menu` — the pulse persisted on the iPhone.

**Fix**: the toolbar menu no longer reads the churning status. `TorrentItem` gained change-guarded stored flags `isPaused`/`canPause` (updated in the status subscriber only when they actually flip), and the toolbar `Menu` moved into a child view `TorrentDetailMenu` that observes only those stable flags (plus its own `copiedMagnet`/`confirmDelete` state). The parent detail body still re-renders for the Status section, but the menu view's inputs are stable, so its toolbar item is not rebuilt.

**Verification**: `swift build` + 53 tests green; deployed to the iPhone.

### 2026-08-08 — Copy Magnet: remove temporary "Copied" label state

`TorrentDetailMenu`'s Copy Magnet item now always shows "Copy Magnet" + `link` icon; the 1.5s "Copied"/`checkmark` state (and its `copiedMagnet` `@State`) was removed — the menu still copies to the pasteboard on tap. Deployed to the iPhone.

### 2026-08-08 — Paused state persists across restarts

Previously paused was intentionally not persisted (a relaunch resumed the download). Now `TorrentStore` persists paused info-hashes in `Documents/paused.json` (mirrors `added-dates.json`):

- `TorrentStore.togglePause(_:)` — the single entry point for pause/resume (detail menu + list swipe now call it); flips the item and adds/removes its id from `pausedIDs`, saving immediately. `remove(_:)` also clears the id.
- `Torrent.init` gained `startPaused: Bool = false`; `TorrentStore.add` passes `pausedIDs.contains(key)` so a restored-paused torrent starts with the flag set.
- `Torrent.run()` publishes status right after the machinery-start decision, so a paused-at-entry torrent immediately emits `.paused` (previously it parked silently and the UI showed stale `.downloading` until resume).

**Test**: `startPausedTorrentParksAndPublishesPaused` — a `startPaused` torrent publishes `.paused` with 0 peers, and `resume()` moves it to `.downloading`. 62 tests green. Deployed to the iPhone.

### 2026-08-08 — Detail view: hide Download/ETA/Peers while paused

When a torrent is paused, its status shows zero rates and no active peers, so `TorrentDetailView`'s Status section now hides the Download, ETA, and Peers rows (`!item.isPaused` guard); Progress and Pieces stay visible. Deployed to the iPhone.

### 2026-08-08 — Detail view kebab menu: plain ellipsis icon + Delete

- Kebab icon changed from `ellipsis.circle` to the ring-free `ellipsis`.
- Added **Delete** to the kebab menu (destructive role, divider above it) with a `confirmationDialog` before removing. `TorrentDetailView` now receives the `TorrentStore` (passed from `ContentView.navigationDestination`) and dismisses after `store.remove(item)` — same delete path as the list's swipe action (removes `.torrent`, data files, and `.verified` sidecar).

### 2026-08-08 — µTP for the metadata fetch + DHT lookup streaming

**µTP metadata fetch** (`MetadataExchange.swift`): `MetadataFetcher` now has `fetchUTP(from:transport:)` — µTP (BEP 29) with a plaintext BT handshake (µTP is its own transport; MSE stays TCP-only, mirroring the download path). The protocol exchange (BT handshake → extended handshake → ut_metadata `_requestPieces`-style all-pieces burst) was extracted into `performMetadataExchange(stream:)` shared by both transports. `MagnetBootstrapper` creates one outbound-only `UTPTransport`, and `fetchMetadata` **races µTP + TCP per peer** (webtorrent's `utpOutgoing` + `tcpOutgoing`): first success wins, loser cancelled; both share the same connect/metadata budget so dead peers still cost ~one timeout. Verified: 5 µTP connects + 4 TCP MSE handshakes in a single resolve run.

**DHT lookup streaming** (`DHTClient.swift`): `lookup` gained an `onPeers` callback (per-`get_peers`-batch delivery, webtorrent's streaming model) and an early-exit at 200 peers so the sweep is fed long before the 20s budget elapses. `MagnetBootstrapper` feeds each batch into the pool immediately.

**Result**: resolve went from never-in-120s → 200s → ~2.9-10s. µTP reaches more peers but does NOT change the resolve time on this swarm — the bottleneck is not transport. Timeline traces show ~5-6s is spent draining the 500 cached `get_peers` records (all stale/NAT'd) and waiting on slow tracker announces (~5.9s for the bulk), before a live tracker peer serves metadata at ~7s. **WebTorrent's ~1.6s comes from a live DHT node**: it ingests `announce_peer` records continuously, so its peer store holds currently-active peers and the first connection attempts hit them. We don't ingest inbound DHT queries (a pure `get_peers` client), so our store is only ever `get_peers` garbage. Closing that gap = implementing inbound DHT query handling (`ping`/`find_node`/`get_peers`/`announce_peer`) + announcing ourselves (BEP 5 node, not just client). 51 tests green.

### 2026-08-08 — DHT is now a node, not a client (BEP 5 inbound queries + self-announce)

The remaining gap to webtorrent's ~1.6s resolve is its **live DHT peer store**: a running DHT node ingests `announce_peer` records continuously, so at resolve time it already has currently-active peers for the swarm and the first connection attempts hit them. We were a pure `get_peers` client — our store only ever held stale `get_peers` records, so every resolution re-drained the dead-peer lottery.

**Changes** (`DHTClient.swift`, `Torrent.swift`):
- **Inbound query handling** in `handleResponse` (was: queries dropped): answers `ping`, `find_node`, `get_peers` (with our cached peers + closest nodes + a token), and `announce_peer` (verifies a per-process-secret token, then stores the announcer as a **live peer** in the cache — the store webtorrent builds). Bad tokens get a 203 error. The receive loop switched to `receiveFrom` so announce_peer has the sender's address.
- **`cacheLivePeers`**: announced peers are inserted ahead of older `get_peers` records (a peer that just announced is, by definition, currently active) — `cachedPeers` now returns confirmed-good, then live-announced, then the rest.
- **Self-announce** (`announce(infoHash:port:)`): gets a token from the closest nodes (reusing table tokens where present), then `announce_peer`s our listen port — so the swarm's DHT stores us. Wired into `Torrent.dhtLoop` (every cycle) and the bootstrapper.
- `DHTClient` gained `addNode(_:)` (PORT-message/webtorrent `dht.addNode`), a `localPort` accessor, `startListening(port:)`, and a configurable `peerCacheURL` for test isolation.
- New `torrent-cli dht-node <infohash>` diagnostic.

**Verification**:
- New loopback tests (`nodeAnswersQueriesAndStoresAnnouncedPeers`, `nodeSelfAnnounce`): node answers ping/find_node/get_peers, rejects a bad announce token, stores an announced peer and serves it back in a later `get_peers`, and `announce()` round-trips a token + stores us at the peer node. 53 tests green.
- **Live**: `dht-node` on the Backrooms infohash does a 438-peer lookup and `DHT: announce 3b124452 to 3 nodes` — the node announced itself to real swarm DHT nodes with valid tokens. Resolve unaffected (3.3-7.0s); the live-store benefit accrues to the long-running app node (its `dhtLoop` announces every 120s), not a one-shot CLI resolve.

### 2026-08-08 — Persistent app-lifetime DHT node (`DHTNode`)

The node's value comes from being a *stable* participant, but `Torrent.dhtLoop` created a fresh `DHTClient` every 120s — a new random node ID + new ephemeral UDP socket each cycle, so nodes that learned us queried a dead identity and we never built a durable DHT position.

**Change**:
- New `DHTNode.swift`: an app-lifetime shared node — ONE `DHTClient` with a **persisted node ID** (`stupid-torrent-dht.nodeid`, stable across launches) and a live socket for the whole session. `DHTNode.shared()` creates/returns it (lock-protected, starts the receive loop); `DHTNode.stop()` for tests/shutdown.
- `Torrent.dhtLoop` uses `DHTNode.shared()` instead of constructing a client per cycle — all torrents participate as one stable node, and the live peer store + routing table accumulate across the session and across launches.
- `MagnetBootstrapper` uses `DHTNode.shared()` (and no longer stops it — it's shared), so magnet resolutions leverage AND contribute to the same warm store as downloads.
- `dht-node` CLI diagnostic switched to the shared node (prints the node ID).

**Verification**: 53 tests green (hermetic tests untouched — they gate on `enableDHT: false` and never touch the singleton). Live: two separate `dht-node` processes report the **same persisted node ID** (`112b4c99`), and the announce now reaches **11 real DHT nodes** (was 3). Resolve unaffected (2.4-8.5s, swarm variance); `add` flow verified end-to-end.

### 2026-08-08 — Keep the screen awake while downloading (`IdleTimer`)

The engine (DHT node, downloads) only runs while the app is foregrounded, and an iOS auto-lock backgrounds + suspends the app — killing the node mid-download. Prevented via `UIApplication.isIdleTimerDisabled`.

**Change** (`IdleTimer.swift`, `Views.swift`): `ContentView` sets the idle timer based on `shouldKeepAwake` = any magnet resolving (`resolvingItems` non-empty) OR any torrent in the `.downloading` state (paused/complete/error don't keep the screen awake). Applied via `.onChange(of: shouldKeepAwake)` and re-applied on scene-phase changes, so a resume from background restores the right state. Follows Apple's guidance of disabling only while needed (battery).

**Verification** (simulator console): on launch `idle timer enabled`; opening a magnet flips to `idle timer disabled (auto-lock off)`; when the resolve ends (success or timeout) it flips back to `enabled`. iOS build via xtool compiles clean; 53 tests green. Note: the app's first resolve in a fresh install on the marginal Backrooms swarm still hits the cold-cache dead-peer lottery (CLI's ~2s times are its warm DHT peer cache) — expected until the app's node warms up; not a regression.

### 2026-08-08 — Reliable magnet resolution (no resolve timeouts)

A fresh-install app resolve timed out at 90s on the marginal Backrooms swarm while the CLI (warm cache) resolved in ~2s and even a **cold** CLI resolved in ~15s — the app's sim DHT returned 0 peers and the single tracker announce's peers were all dead. "Timing out is unacceptable" → fixed three ways:

1. **Tracker re-announce loop** (`MetadataExchange.swift`): the streaming-sweep restructure had dropped the old round-based re-announce — trackers announced ONCE, so an all-dead first list meant 90s of sweeping stale peers. Restored as a background `trackerTask` that re-announces every 15s, feeding fresh peer lists into the pool (new lottery tickets as the swarm churns). Cancelled on success/timeout.
2. **Resolve deadline 90s → 180s**: the app no longer gives up on a swarm that has seeders but is slow to surface them (worst-case CLI baseline was 200s).
3. **DHT node warm-up at app launch** (`DHTNode.warmUp()` called in `stupid_torrent_clientApp.init`): bootstraps the shared node's routing table in the background, so the first magnet resolve doesn't pay a cold 8s bootstrap inline and queries a warm table (also starts accumulating the live peer store immediately).

**Verification**: cold-cache CLI resolve x3 all succeed (21.4s first, then 3.3s/3.0s as caches warm); 53 tests green. Simulator: at launch the node is already live (`DHT: announce … to 8 nodes`, warm-up ran), and adding the Cosmos Laundromat magnet resolves and persists within ~20s (sweep-cancelled `CancellationError`s confirm a peer won; `.torrent` saved; idle timer held disabled while downloading).
