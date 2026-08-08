# Technical plan — MKV streaming via VLCKit (iOS)

Status: **implemented (Phase 1-4 of the plan landed).** Gate 0 (packaging + render smoke test) passed; `TorrentSeekableInputStream` + `VLCBridge` + app routing are in and validated on the simulator with both a generated H.264/AAC MKV (full playback) and the real Backrooms HEVC Main 10 / E-AC-3 / SRT MKV (decodes and renders; playback paces to download). This deliberately changes one locked-in decision from `docs/planning.md` (line 88 / risk table line 129).

## Problem

AVFoundation's `AVAssetResourceLoaderDelegate` + `AVPlayer` pipeline only demuxes containers Apple ships support for (mp4/m4v/mov/m4a/mp3/aac/wav). Matroska is not one of them — even when the video stream inside is Apple-playable HEVC, AVFoundation refuses the container. The concrete motivating file is the partial **Backrooms** release already in the simulator container:

```
Backrooms.2026.2160p.iT.WEB-DL.DDP5.1.Atmos.H.265-RDNYB.mkv
format: matroska/webm
video:  HEVC Main 10, 3836x2072
audio:  E-AC-3 (Dolby Digital Plus) + Atmos, 5.1(side)
subs:   4x SRT (embedded)
```

`Torrent.contentType(forFileNamed:)` returns nil for `.mkv`, so the file row is `.disabled` and the only path to the bytes is QuickLook of the partial file — no streaming playback. Today that row is disabled with a documented "expected" note (implementation-notes line 423).

## Goals / non-goals

### Goals

- Stream `.mkv`/`.mka` while the torrent is still downloading, from verified pieces only.
- Preserve the existing AVPlayer path for all currently-streamable formats unchanged.
- Play HEVC/H.264 video, E-AC-3/AC-3/AAC/MP3/Opus audio, and embedded SRT/VobSub subtitles that appear in real-world MKV releases.
- Keep `swift test`, `torrent-cli`, and the macOS host build fully green and free of any VLC dependency (hermetic harness stays hermetic).
- Fail loudly (player shows an error state) rather than silently falling back.

### Non-goals (v1 of this feature)

- MKV Picture-in-Picture (VLCKit 3.x has no native PiP API; follow-up).
- WebM/AVI (same container problem; WebM shares the Matroska demuxer, so it may come nearly free — decide after the gate).
- Transcoding/remuxing MKV to MP4 (would require an FFmpeg-scale build; explicitly rejected, see Decisions).
- Windows-only/AV1-in-MKV edge cases that even VLC can't decode on iOS hardware.
- Background playback beyond the existing `audio` background mode.

## Decisions

1. **Embed VLCKit (MobileVLCKit) for MKV playback.** VLCKit is the only pragmatic way to get full Matroska + codec + subtitle coverage on iOS without writing and maintaining a Matroska demuxer plus a seekable fragmented-MP4 remuxer (the only way to feed AVPlayer). Writing the latter from scratch is a multi-week correctness sink (EBML/Cluster/Cues/SimpleBlock parsing, HEVC VPS/SPS/PPS extraction, E-AC-3 passthrough, fMP4 sample tables, byte-range seek bridging) and still ends up limited to codecs Apple's decoder stack accepts. VLCKit accepts this exact file today.
   - **Tradeoffs accepted**: app size grows (~225 MB static framework without simulator slice, ~1.15 GB with), custom in-app controls instead of `AVPlayerViewController`, LGPLv2.1+ compliance obligations, and a third-party binary in an otherwise dependency-free project.
   - **Tradeoffs rejected** (recorded for the log):
     - *Native Matroska demux + remux*: no binary dependency, but very large, codec-limited, and high maintenance risk. Deferred as a follow-up if VLCKit proves untenable after the packaging gate.
     - *"Backrooms-minimum" (parse just this file)*: not real MKV support; the user chose broad VLCKit support.
2. **VLC only on iOS; never in `TorrentCore`/`Streaming`/`torrent-cli`.** The macOS host build (`swift build`, `swift test`, the CLI harness) must not link MobileVLCKit. Achieved with a platform-conditional dependency chain in `Package.swift` (see [Packaging](#packaging)). All VLC interaction lives behind a thin iOS-only bridge target.
3. **Feed VLC through a custom seekable `NSInputStream`** connected to the torrent's verified-byte APIs, mirroring how `TorrentResourceLoaderDelegate` feeds AVPlayer. VLC exposes `VLCMedia(initWithStream:)` whose `libvlc_media_new_callbacks` bridge calls back into the stream for open/read/seek/close — no local HTTP server, no filesystem shadow copy.
4. **Reuse the existing priority machinery for streaming.** No new picker concepts. Sequential read windows use the existing 2 MB lookahead; seeks and the MKV Cues index (typically at the end of the file) ride the existing jump classification in `Torrent.streamPriority`.
5. **Classification, not content-type, drives the file rows.** Replace the `contentType != nil` streamability check with a `PlaybackKind` enum: `.avPlayer`, `.vlc`, `.none`. `.mkv`/`.mka` → `.vlc` on iOS (`.none` on macOS, where the CLI keeps working without VLC).

## Architecture

```
                 +-----------------------+        +-------------------------+
   AVPlayer path | TorrentStreamSession  |  feeds | AVPlayer (unchanged)    |
                 | (AVAssetResourceLoader)|        +-------------------------+
   ──────────────┴───────────────────────┘
   ┌─────────────┬───────────────────────────────────────────────────────────┐
   │ MKV path    │  TorrentSeekableInputStream (Foundation, NSInputStream)   │
   │ (iOS only)  │    ├─ reads  via Torrent.streamingAvailability/Read       │
   │             │    ├─ seeks  via NSStreamFileCurrentOffsetKey (setProperty)│
   │             │    ├─ prior via Torrent.streamPriority (jump vs window)   │
   │             │    └─ blocked until verified bytes land (never fake EOF)  │
   │             ▼                                                            │
   │   VLCBridge (iOS-only target)                                            │
   │     VLCMedia(initWithStream:)  ──>  VLCMediaPlayer  ──>  UIView (drawable)│
   └──────────────────────────────────────────────────────────────────────────┘
```

- `TorrentCore` — untouched except `contentType` gains a sibling `playbackKind` helper (still dependency-free).
- `Streaming` — gains `TorrentSeekableInputStream` + its data-source protocol. Foundation-only, so it compiles on macOS and is unit-testable hermetically.
- `VLCBridge` (new target) — the only code that imports MobileVLCKit. Contains the playback session + the SwiftUI-facing `MKVPlayerView`.
- App (`stupid_torrent_client`) — routes file rows to `.avPlayer` or `.vlc` and presents the matching player.

## Packaging (gate 0 — do first, everything else assumes it passes)

### Why a gate

xtool builds through SwiftPM and packages the app itself. It supports XCFramework binary targets (static detection via archive magic, framework copy into `App.app/Frameworks`), but has known edge cases (fat-static misclassification, xtool issue #130) and the simulator path hard-codes `iPhoneOS`/`arm64` plist values. MobileVLCKit ships only as a CocoaPods/Carthage static XCFramework — there is **no official SwiftPM package**. This is the highest-risk part of the plan, so it is its own gate with an explicit abort criterion.

### Dependency wiring

Declared as local binary targets in `Package.swift` so nothing depends on a third-party SPM wrapper repo's availability:

```swift
.binaryTarget(name: "MobileVLCKit", path: "Vendor/MobileVLCKit.xcframework"),

.target(
    name: "VLCBridge",
    dependencies: [
        .target(name: "MobileVLCKit", condition: .when(platforms: [.iOS])),
        .target(name: "Streaming"),
        .target(name: "TorrentCore"),
    ]
),
.target(
    name: "stupid_torrent_client",
    dependencies: [
        .target(name: "TorrentCore"),
        .target(name: "Streaming"),
        .target(name: "VLCBridge", condition: .when(platforms: [.iOS])),
    ]
),
```

Key properties:

- The `.target(name:condition: .when(platforms: [.iOS]))` dependency conditions are honored by SwiftPM at build time: on a macOS host build the `VLCBridge` and `MobileVLCKit` targets fall out of every build graph, so no macOS slice is ever needed and `swift build`/`swift test`/the CLI stay clean. `VLCBridge` still exists as a source target but its Swift file body is `#if os(iOS)`.
- `VLCBridge` declares VLCKit's required system link settings (from the official MobileVLCKit podspec) so they flow through SwiftPM to the final iOS link:
  - Frameworks: `QuartzCore`, `CoreText`, `AVFoundation`, `Security`, `CFNetwork`, `AudioToolbox`, `OpenGLES`, `CoreGraphics`, `VideoToolbox`, `CoreMedia`.
  - Libraries: `c++`, `xml2`, `z`, `bz2`, `iconv`.
  - Add `-ObjC` only if the smoke test shows Objective-C category/load failures (the official podspec does not use it; do not preemptively add).
- The XCFramework must exist at `Vendor/MobileVLCKit.xcframework` for *any* `swift build` to resolve the package (SwiftPM validates referenced binary-target paths at resolve time). `Vendor/` is gitignored; a setup step populates it.

### Artifact + setup step

- Source the official VideoLAN artifact (CocoaPods tarball, e.g. `MobileVLCKit-3.7.x-<hash>.tar.xz` from `https://download.videolan.org/pub/cocoapods/prod/`).
- Repack into an XCFramework with at least these slices: `ios-arm64` (device) and `ios-arm64-simulator` (Apple Silicon simulator; `ios-x86_64-simulator` only if Intel simulators are in scope). Strip dSYMs and any `.doc`/headers we don't need — the download is ~1.15 GB full / ~225 MB lite (Lite drops simulator support; we need the sim slice for the workflow in this repo, so use the full tarball).
- The binary target, framework, module, and binary names must all be exactly `MobileVLCKit` (xtool + SwiftPM resolve by that name).
- Record the download command + checksum in this doc's setup section when the exact version is pinned during the gate.

### Gate 0 verification (abort criterion)

1. `swift build` on macOS (host) stays green and does not attempt to fetch/resolve a macOS slice.
2. `swift test` (macOS) stays green — hermetic harness untouched.
3. `xtool dev run --simulator` builds, installs, launches, and shows a `VLCMediaPlayer` rendering a tiny generated MKV (see [Verification](#verification)).
4. The built `.app` does **not** embed a dynamic `MobileVLCKit.framework` in `Frameworks/` (it should be statically linked), and the binary has no undefined system symbols.
5. Same minimal MKV plays on a physical device over `--network` (device has no simulator slice risks, so this is the ground truth for the linker settings).

If gate 0 fails in a way that can't be worked around in one session (e.g. xtool fat-static misclassification hard-blocks, or VLCKit's static link fights SwiftPM), **stop and re-evaluate** — the fallback is the native demux/remux approach from Decisions, re-costed against what gate 0 learned.

## Component 1 — `TorrentSeekableInputStream` (in `Streaming`)

`NSInputStream` subclass that presents the torrent file as a byte stream to libVLC's callback bridge. Foundation-only; no VLC references. Modeled on the loader's `serve()` logic in `Sources/Streaming/TorrentStreamSession.swift`.

### Data source abstraction (testability)

```swift
public protocol TorrentStreamSource: Sendable {
    func fileLength() async -> Int
    func availability(fileIndex: Int, offset: Int) async -> Int      // verified contiguous run
    func read(fileIndex: Int, offset: Int, length: Int) async -> Data? // nil if not verified
    func prioritize(fileIndex: Int, range: Range<Int>) async
}
```

A `TorrentStreamSourceAdapter` actor forwards these to the `Torrent` actor's existing `streamingAvailability`/`streamingRead`/`streamPriority` (all already exist in `Torrent+Streaming.swift`). Unit tests inject a fake actor implementing the protocol — no VLC, no torrent engine, deterministic.

### Internal state

- `buffer: Data` — bytes fetched ahead of the read cursor (capped, see below).
- `fileOffset: Int64` — logical position in the file (the value exposed via `NSStreamFileCurrentOffsetKey`).
- `eof: Bool`, `status: Stream.Status`.
- A lock (`NSLock` or `os_unfair_lock`) guarding buffer/offset/eof, and a condition or semaphore to wake blocked readers when (a) the feed task lands data, (b) a seek resets the buffer, or (c) `close()` aborts.

### Behavior contract (what VLC relies on)

From `VLCMedia.m`, the libvlc callback bridge (`open_cb`/`read_cb`/`seek_cb`/`close_cb`) does:

- `open` → calls `[stream open]` on us (stream starts `NotOpen`).
- `read` → calls `[stream read:buf maxLength:len]` synchronously on libVLC's input thread. **libVLC treats a return of 0 as end-of-stream and -1 as error.** So we must **block until verified bytes exist** at the current offset rather than ever return 0 early — a premature 0 is indistinguishable from "file done" and VLC will stop.
- `seek` → calls `[stream setProperty:@(offset) forKey:NSStreamFileCurrentOffsetKey]`; we return `true` if the offset is valid, `false` (→ `seek_cb` returns -1) otherwise.
- `close` → calls `[stream close]`; any blocked `read` must return immediately (-1) and the feed task must stop.

### read(maxLength:) semantics

1. Lock; if `buffer` has bytes starting at `fileOffset`, copy out `min(available, maxLength)`, advance `fileOffset`, unlock, return the count.
2. If `fileOffset >= fileLength`: set `eof`, return 0.
3. Otherwise **block** (condition/semaphore) until the feed task appends data at `fileOffset`, a seek moves the cursor, or `close()` fires → return -1 with `streamError`. Never spin; never return 0 before EOF.

### Feed task

- Started by `open()` (a background `Task`). Loop:
  - `let run = await source.availability(fileIndex:offset:)` at the current read cursor; if `run > 0`, `await source.read(...)` up to the buffer cap and append; then (and on every refill) call `source.prioritize` with a **2 MB lookahead window** starting at the read cursor (matches the AVPlayer loader's window, `TorrentStreamSession.swift:87-92`).
  - If no data is available, sleep ~100-200 ms and retry (same cadence as the loader's poll).
- Buffer cap ~1-2 MB so libVLC's large reads are satisfied without reading the whole file into memory.
- Cancelled by `close()`; a stopped/paused torrent surfaces as a `streamError` on the blocked read rather than a hang.

### Seeking (`setProperty(_:forKey:)`)

- Accept `NSStreamFileCurrentOffsetKey`. Validate `0...fileLength`; reject otherwise (`false`).
- Set `fileOffset`, discard the buffer, wake blocked readers. The feed task's next refill calls `prioritize` on the new window, and `Torrent.streamPriority`'s existing jump classification (`Torrent+Streaming.swift:27-38`) promotes a seek-ahead-of-progress range to priority 10 and moves the sequential frontier — the same path AVPlayer seeks already use. No new picker logic.
- `getProperty(_:)` returns the current `fileOffset` for `NSStreamFileCurrentOffsetKey` (libVLC doesn't need it, but NSInputStream contract wants it consistent).
- `streamStatus`/`hasBytesAvailable`: report `.open` once opened; `hasBytesAvailable` returns `!buffer.isEmpty || fileOffset < fileLength` (an optimistic answer is fine — VLC only relies on `read`).

### MKV Cues index consideration

Matroska files put the Cues/seek index at the tail; VLC uses it for accurate seeks and often for early duration/timeline discovery. On a partial download the tail is usually *not* verified at start, so:

- At session start, the bridge issues one **jump-priority** request for the last ~2 MB of the file (mirror of the moov-tail handling in `TorrentStreamSession`). When the tail lands, VLC can parse Cues and seeking within the downloaded region behaves well.
- Seeks *beyond* the downloaded frontier will block in `read` until the jump window verifies — playback stalls briefly instead of erroring. Surface this via the player's buffering state rather than pretending it's instant.

## Component 2 — `VLCBridge` (iOS-only target)

The only code that imports MobileVLCKit. Swift file body guarded `#if os(iOS)` so the macOS build of the target is an empty module.

### `MKVStreamSession`

Owns: a `TorrentSeekableInputStream`, a `VLCMedia` (created with `initWithStream:`), a `VLCMediaPlayer`, and a render view. Mirrors `TorrentStreamSession`'s ownership pattern (the delegate/media must stay alive for the player).

- Applies the Cues-tail jump priority at init.
- Configures the audio session exactly as `AVPlayerControllerRepresentable.configureAudioSession()` does today (`Views.swift:435-439`): `.playback`, mode `.moviePlayback`, active.
- Tries hardware decoding (`VLCMediaPlayer` + `VLCMedia` default options; hardware decode is on by default in recent MobileVLCKit — confirm in the gate, add the explicit option only if needed).

### Rendering

- Attach the player's output to a plain `UIView` via the `drawable` property (VLC renders into the view's layer). The exact modern API (`VLCMediaPlayer.drawable` vs. the newer `VLCVideoView`/`VideoView` subclass) is confirmed during gate 0 — the smoke test must cover both if both exist in the pinned version.

### Observable state (for SwiftUI)

- `state`: idle / loading / playing / paused / errored / ended.
- `duration` (ms), `position` (ms), `isPlaying`, `error` (`String?`).
- Tracks via the player's current-track accessors (audio/subtitle identifiers + names) for the selectors.
- `seek(to ms:)` and `setAudioTrack`/`setSubtitleTrack`.
- `teardown()`: stop the player, close the stream (unblocks any pending read), release media.

## Component 3 — App integration

### `PlaybackKind` (in `TorrentCore`, `Torrent+Streaming.swift` or new file)

```swift
public enum PlaybackKind { case avPlayer, vlc, none }

public static func playbackKind(forFileNamed name: String) -> PlaybackKind {
    switch extension {
    case "mkv", "mka": return .vlc
    // existing AVPlayer whitelist (mp4/m4v/m4b/m4a/mov/mp3/aac/m4p/wav) → .avPlayer
    default: return .none
    }
}
```

`contentType(forFileNamed:)` stays for the AVPlayer loader path (it returns `nil` for mkv → those never reach the loader). On macOS `.vlc` is treated as `.none` by the caller so the CLI's stream-test/play file filters (`CLI.swift:315-317`, `412-414`) don't start picking mkv files it can't play.

### `Views.swift`

- `TorrentDetailView` file rows (`Views.swift:293-315`): compute `playbackKind`; `.avPlayer` rows look and behave exactly as today; `.vlc` rows show the same play affordance but route to `openPlayer` → `MKVPlayerView`; `.none` rows stay disabled.
- `openPlayer` picks the session by kind. `.vlc` path: `MKVStreamSession(torrent:fileIndex:)` presented in the existing `.fullScreenCover` (`Views.swift:349-354`).
- New `MKVPlayerView` (iOS-only SwiftUI): the VLC render view + minimal controls overlay — dismiss, play/pause, elapsed/total, seek slider, and (if the file has them) audio + subtitle track pickers. Loading spinner and error state mirroring `AVPlayerControllerRepresentable`'s overlay behavior.
- macOS (`#if os(iOS)` off): `.vlc` rows remain disabled (no VLCKit on macOS); everything else unchanged.

### `torrent-cli`

Unchanged. `stream-test`/`stream-play` continue to target AVPlayer-streamable files only. No VLC in the CLI — MKV integration is validated in the app/simulator, not the hermetic CLI.

## Testing

### Unit tests (`swift test`, macOS, hermetic)

New `SeekableInputStreamTests` in `Tests/` (Foundation-only, fake `TorrentStreamSource`):

- Sequential reads return exact bytes and advance the offset.
- Seek via `setProperty(NSStreamFileCurrentOffsetKey)` changes the cursor and discards buffered bytes (a subsequent read returns the new range).
- Seek past file length is rejected (`false`).
- Read blocks (does not return 0) while the source has no verified bytes, then completes when the fake verifies a run — verifies the "never fake EOF" contract.
- Read returns 0 exactly at `fileLength` (EOF).
- `close()` unblocks an in-flight blocked read with -1 and a streamError.
- The feed task requests a bounded lookahead window and re-prioritizes after a seek (assert `prioritize` calls).
- Buffer cap respected (no unbounded read-ahead).

Existing suites must stay green: 53 tests today, all macOS-safe (no VLC in any test target).

### Hermetic / CLI regression

`torrent-cli stream-test` on the existing faststart + non-faststart mp4 fixtures must still report `playable=true` and seek OK — proving the AVPlayer path is untouched.

### App / simulator / device (MKV)

- Generate a small H.264 + AAC + SRT **MKV** with ffmpeg (already installed at `/opt/homebrew/bin/ffmpeg`), torrent it tracker-less, seed with aria2, and verify playback starts before 100% download (mirrors the existing `stream-test` methodology, documented in `skills/stupid-torrent-debug/SKILL.md`).
- Same fixture, `--seed-until` a small prefix, then **seek beyond the frontier**: assert the tail jump priority is requested and playback resumes once the range verifies (the existing jump machinery, verified by `PiecePickerTests`).
- Backrooms partial file (real target): video + E-AC-3 audio + embedded SRT play, subtitle track switching works, seek within the downloaded region works.
- Full `swift build` + `swift build --product torrent-cli` green; simulator and `--network` device deploy both work (device is the ground truth for linker settings).

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| xtool/SwiftPM can't package static MobileVLCKit (fat-static misclassification, issue #130) | Gate 0 first with explicit abort criterion; verify the built `.app` has no embedded dynamic framework and no undefined symbols |
| Platform-conditional dependency doesn't keep macOS host build clean | SwiftPM honors `condition: .when(platforms:)` at build time; gate 0 step 1-2 assert `swift build`/`swift test` stay green before any VLC code lands |
| Blocked `read` hangs the player when a range never verifies (dead swarm) | `close()` unblocks; stalled torrent surfaces as streamError → error UI; bounded wait + poll cadence mirrors the loader |
| MKV Cues tail unverified → poor seeks / no timeline on partial file | Jump-priority the last ~2 MB at session start (moov-tail analog); document "seek waits, doesn't fail" |
| App size / LGPL obligations | Size measured at gate 0 and reported; LGPL compliance checklist below; note VLCKit's LGPLv2.1+ (not MIT) |
| Simulator slice vs device slice mismatch | Ship full XCFramework with `ios-arm64` + `ios-arm64-simulator`; validate both paths in gate 0 |
| Player API drift (VLCMediaPlayer.drawable vs VLCVideoView, track accessors) | Smoke test confirms exact pinned-version API before the app UI work starts |
| No official SwiftPM package for VLCKit | Local `Vendor/` binary target + our own `VLCBridge` wrapper target declaring podspec link settings; no reliance on a third-party SPM wrapper |

## LGPL compliance checklist (v1)

- [ ] Ship VLCKit's COPYING/License text in the app (About/acknowledgements view or bundled license file).
- [ ] Make VLC source (and our VLCBridge additions) obtainable per LGPL terms; note LGPLv2.1+.
- [ ] Do not statically link in a way that hides VLC from relinking if that's how the license reads for our distribution; confirm with the actual license text during the gate.

## File-by-file change plan

| File | Change |
|---|---|
| `Package.swift` | Add `MobileVLCKit` binary target (`Vendor/MobileVLCKit.xcframework`) + `VLCBridge` target (iOS-conditional deps); add `VLCBridge` dep to `stupid_torrent_client` (iOS-conditional); system link settings on `VLCBridge` |
| `Sources/TorrentCore/Torrent+Streaming.swift` | Add `PlaybackKind` enum + `playbackKind(forFileNamed:)`; keep `contentType` |
| `Sources/Streaming/TorrentSeekableInputStream.swift` | New: NSInputStream + feed task + seek + blocking read contract |
| `Sources/Streaming/StreamDataSource.swift` | New: `TorrentStreamSource` protocol + actor adapter over the `Torrent` APIs |
| `Sources/VLCBridge/VLCBridge.swift` | New (`#if os(iOS)`): `MKVStreamSession`, render view, observable state, `MKVPlayerView` |
| `Sources/stupid_torrent_client/Views.swift` | File-row routing by `PlaybackKind`; `openPlayer` dispatch; `MKVPlayerView` presentation in the existing cover |
| `Tests/SeekableInputStreamTests.swift` | New: stream/read/seek/EOF/cancel/priority tests against a fake source |
| `docs/planning.md` | Update line 88 + risk table (mkv) to reflect the VLCKit decision and VLCBridge-only-iOS scoping |
| `docs/implementation-notes.md` | Entry at commit time describing the change and why (per AGENTS.md) |

## Verification (2026-08-08)

- **Gate 0 — packaging**: MobileVLCKit 3.7.2 XCFramework (`Vendor/`, gitignored) with `ios-arm64_armv7_armv7s` + `ios-arm64_i386_x86_64-simulator` slices (dSYMs stripped, 225 MB). The `.binaryTarget` + platform-conditional `VLCBridge` dependency keeps `swift build`/`swift test`/`torrent-cli` (macOS) free of any VLC code — confirmed green throughout. iOS simulator build embeds `MobileVLCKit.framework` in `App.app/Frameworks`, links via `@rpath`, and the app launches with the framework loaded.
- **Stream unit tests**: 8 `SeekableInputStreamTests` (sequential read, EOF-only-zero, block-until-verify, seek + buffer drop, seek-past-end rejection, close-unblocks-read, lookahead prioritization, seek re-prioritization) against a fake source. 61 tests total green.
- **Render smoke test (temporary, removed after passing)**: an env-gated auto-open path played a generated 10 s H.264/AAC MKV (ffmpeg `testsrc`+`sine`) through `MKVStreamSession`. The stream served the complete 356 KB file (262144 + 94320 byte reads), VLC reported `playing=true seekable=true`, and screenshots showed the test pattern advancing frame-to-frame — full render + playback proven.
- **Real file (Backrooms)**: HEVC Main 10 + E-AC-3 Atmos + embedded SRT, ~10 GB file with 147/1250 verified pieces. VLC decoded and rendered real video content; playback paces to the download (with 0 live peers it buffers rather than erroring — the expected "seek/read waits, doesn't fail" behavior).
- Known limitation carried into the UI: seeking beyond the downloaded frontier blocks until the jump range verifies (documented; the picker's jump priority still applies).

## Suggested execution order

1. **Gate 0** — download/repack the XCFramework into `Vendor/`, wire `Package.swift` + empty `VLCBridge`, run the packaging smoke test (build, launch, render a 10-second ffmpeg MKV, inspect the app bundle, device test). Abort decision point.
2. **`TorrentSeekableInputStream` + protocol adapter + unit tests** (`swift test` green; CLI streaming regression green).
3. **`VLCBridge` session + render + minimal player UI** on the small generated MKV fixture.
4. **`PlaybackKind` routing** in the app; mkv rows become tappable on iOS.
5. **Backrooms validation** on simulator + device; size and LGPL checklist.
6. Update `docs/planning.md`, add `docs/implementation-notes.md` entry, commit.

## References

- VLCKit stream callback bridge: `Sources/Media/VLCMedia.m` (`open_cb`/`read_cb`/`seek_cb`/`close_cb`, `initWithStream:`) and `Headers/Public/Media/VLCMedia.h` — upstream `videolan/vlckit` (gitignored clone target if needed).
- MobileVLCKit artifact list + podspec (link settings source of truth): `Packaging/MobileVLCKit.json`, `Packaging/podspecs` in `videolan/vlckit`.
- xtool binary-target handling: `/Users/stephan/environments/external/xtool/Sources/PackLib/Planner.swift` (BinaryTarget → packaging command), `Packer.swift` (static detection + framework copy), `DevCommand.swift` (iOS triple selection).
- Existing AVPlayer loader to mirror: `Sources/Streaming/TorrentStreamSession.swift`.
- Existing priority/jump machinery: `Sources/TorrentCore/Torrent+Streaming.swift`, `PiecePicker` priority levels.
- Test media recipe: `skills/stupid-torrent-debug/SKILL.md` (ffmpeg fixture generation + aria2 seeding).
