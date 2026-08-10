# Handover — MKV streaming: wrong duration + long spinner

Status: **resolved in the working tree.** See "Resolution" below.
Date: 2026-08-10.

## Resolution

The fix deliberately separates AVFoundation's partial fragmented-MP4 duration from the duration shown by the player:

1. MKV/MKA all-to-end resource-loader requests finish at the current readable frontier instead of polling indefinitely. The `long30.mkv` loader-path regression completes in about 0.5 s; bounded far-seek requests retain their wait-for-verification behavior.
2. `TorrentStreamSession.makePlayerItem()` reads `MatroskaInfo.durationSeconds` and returns a duration-overriding `AVPlayerItem`, which is used by the app and `stream-play`. Native controls therefore show the declared total duration (`6459.197s` for MTP) while the raw asset remains free to represent only readable fragments.
3. Precomputed layouts now exclude dropped tracks. MTP has subtitle-only clusters which were previously included in `sidx`/fragment sizing even though no subtitle fragment is emitted, causing zero-byte reads at the first such cluster.

The experimental `mehd` production changes and scratch test were removed. A real MTP `stream-test` run reported `PLAYER ITEM: duration=6459.1967s`; the command's dual-torrent raw `AVAsset.duration` remained unstable (`37.871s` in that run), so raw asset duration is intentionally not the player UI source of truth.

Follow-up: MTP's default 5.1 audio plus two commentary tracks were all emitted as independently enabled MP4 tracks, which made AVFoundation mix them. `MKVRemuxer` now emits only the enabled default audio track (falling back to the first supported audio track); the real-file harness reports `audioTracks=1`.

Far-seek follow-up: overriding `AVPlayerItem.duration` changed the displayed duration but AVFoundation still clamped seeks to its raw readable-fragment duration. `TorrentSeekingPlayer` now intercepts native seeks, uses the Matroska `SeekHead`/Cues index to prioritize and remux from the target keyframe, replaces the item with a fresh local-timeline asset, and translates item time back to global movie time. The MTP harness jumps from 5.5 s to 5000.3 s and continues playback; the partial `long30.mkv` regression verifies that the middle byte range is not downloaded.

Cues-less partial MKVs do not use the declared-duration override or `TorrentSeekingPlayer`; native controls are limited to the currently readable timeline. Fully downloaded Cues-less files remain seekable through the precomputed structural layout.

Playback-stall follow-up: never finish an AVFoundation `requestsAllDataToEndOfResource` playback request at an arbitrary byte cap. iOS treats that as EOF and stopped MTP at the first fragment. Playback requests remain open and suspend briefly every 4 MiB to provide backpressure. Laced AAC frames also use a 48 kHz track timescale and exact 1024-sample durations instead of zero-duration samples.

Far-seek video follow-up: preserve `CueTrack`, select the retained video track's Cue position, and rebase the target segment's PTS/DTS to zero. Each seek uses an isolated transmux source and unique asset URL, waits for that playback asset's `.isPlayable`, and applies the global time offset only in `TorrentSeekingPlayer.currentTime()`. Reusing the original source/URL or exposing global timestamps inside `AVPlayerItem.currentTime()` produced a moving progress bar with an unchanged frame.

## The bug (as reported)

Open the "Meet the Parents 2000 REMASTERED 1080p BluRay HEVC x265 5.1 BONE" MKV (`.mkv`,
2,130,538,275 B, 1016 pieces @ 2 MiB) from the torrent detail view in the iOS simulator
(PlayerView → AVPlayerViewController via the transmuxer). User reports:

1. **Spinner for a long time** before playback starts.
2. Once playing, **the duration shows ~8 minutes**; the movie is actually ~108 min
   (MKV head declares `durationSeconds = 6459.2`).

The movie itself plays correctly once it starts (HEVC 1080p 23.976 fps, AAC 5.1). The problem
is purely duration/seek-timeline metadata, and it only affects **partially-downloaded MKVs**
(streaming mode). A fully-downloaded MKV reports correct duration (sidx path).

## Architecture / how MKV gets to AVPlayer

- `TorrentStreamSession` routes `.mkv`/`.mka` through `TransmuxStreamSource`
  (`Sources/Streaming/TransmuxStreamSource.swift`), which presents a *virtual fragmented MP4*
  (`[init segment][fragment 0][fragment 1]…`) to AVPlayer's `AVAssetResourceLoaderDelegate`.
- Two serving modes:
  - **Precomputed (complete file)**: whole MKV verified → a structural scan sizes every
    fragment, a `sidx` is emitted in the init segment, exact content length + seeking. This path
    reports correct duration (verified in-app and hermetically).
  - **Sequential (streaming / partial download)**: fragments generated on demand from verified
    bytes, **no sidx** (future fragments unknown). This is the broken path.
- The MKV's total duration is known immediately from the head
  (`MatroskaParser` → `info.durationSeconds`, read in `ensureHead`), but the streaming init
  segment currently carries **zero duration info**: `TransmuxTrack.durationTicks` is hardcoded
  to 0 in `MKVRemuxer.init` (`Sources/Streaming/Transmuxer.swift:45`), so mvhd/tkhd/mdhd all
  say duration 0, and there's no sidx/mehd.

## Root cause

AVFoundation computes the duration of a **fragmented MP4 by summing the durations of the
fragments it can actually read** from the resource. It does not trust header hints for
fragmented files (see "Findings", all empirically verified with scratch tests on `long30.mkv`,
a 30 s fixture, and on the real MTP file via the CLI harness).

For a partial download, the transmuxer can only emit fragments for the verified prefix, so:

- AVFoundation reads fragments until it hits the download frontier, then reports the sum of
  what it could read ≈ the downloaded portion of the movie (~8 min when ~10 % was downloaded).
- The loader (`TorrentResourceLoaderDelegate.serve` in `Sources/Streaming/TorrentStreamSession.swift`)
  holds the all-to-end request open, polling every 200 ms for more verified bytes, so
  `asset.load(.duration)` blocks → the long spinner. (In the CLI `stream-test`, this manifests
  as the `asset.load(.duration)` call hanging past the 30 s harness timeout and the CLI being
  killed; see Repro below.)

## Findings (empirical, from `Tests/StreamingTests/DurationScratchTests.swift`)

All verified on the **macOS host** by building fMP4 bytes, writing to a temp file (file path)
and/or serving through `TorrentResourceLoaderDelegate` (loader path, the real app path). Fixture
`Fixtures/mkv/long30.mkv` = 30.023 s declared.

1. **Baseline (durations 0, no sidx)**: complete file → AVFoundation reports 30 s (correct, by
   summing all readable fragments). Partial (first 30 % readable) → reports ~13.3 s (sum of
   readable fragments). This is the core behavior causing the 8-min bug.
2. **`mehd` box** (movie extends header, the ISO-BMFF way to declare total fragmented duration):
   ignored. Init-only file → `duration=0`; partial → still fragment-sum; complete → still 30 s.
   `ffprobe` also reports N/A for it.
3. **`mvhd` duration set (tracks 0)**: ignored / gives garbage (init-only → 0; full → 25.08 s;
   partial → fragment-sum). Not usable.
4. **Track durations set (tkhd/mdhd/mvhd from declared total)**: **causes doubling** — complete
   30 s file reports 60.02 s (declared + fragment-sum added together). Matches the older note in
   `docs/implementation-notes.md`: *"mvhd/tkhd/mdhd durations must be 0 for fragmented files
   (AVFoundation sums them with the fragment duration → doubled playback length)."*
5. **`sidx` box**: ignored for *duration*. A valid sidx whose references claim 2× duration still
   reports the real 30 s; a single fake 100 s reference also reports 30 s. (sidx is honored for
   seeking, not for total duration, in these tests.)
6. **Loader path ≠ file path in one respect**: partial-via-loader duration load takes ~9 s
   (spinner) vs ~0.02 s for file path; it polls the source waiting for the frontier to advance.
7. **Complete MTP file via the CLI `stream-test` harness still reported `duration=9.76s`**
   (not 6459 s), even though the file was 1016/1016 verified. Caveat: that harness runs two
   `Torrent`s on the same dir (the `stream` torrent re-verifies on startup and may race the
   asset load), so it's inconclusive on its own — but it hints the loader-path duration may be
   off for large files even when complete. Decisive check: load the complete MTP file through a
   single `Torrent` + `TransmuxStreamSource` in the app (or a single-torrent CLI) and read
   `asset.duration`. If it's wrong even when complete, the sidx/complete path needs a closer
   look, not just the streaming path.

Net: **there is no init-segment-only mechanism that makes AVFoundation report the true total
duration for a partially-available fragmented MP4.** Duration is derived from readable fragment
data, period.

## What was tried (code changes present in the working tree, NOT committed)

Experimental, still in the tree (see `git diff`):
- `MP4Muxer.initSegmentWithMehd(tracks:movieDurationTicks:)` + `mehd` emission in `mvex`
  (`Sources/Streaming/MP4Muxer.swift`).
- `MKVRemuxer.initSegmentForStreaming()` — streaming init carrying the MKV-declared duration
  via mehd (`Sources/Streaming/Transmuxer.swift`).
- `TransmuxStreamSource.ensureHead` now calls `initSegmentForStreaming()`.
- `torrent-cli head-parse <file.mkv>` debug command (`Sources/torrent-cli/CLI.swift`) — prints
  parsed head (timescale, duration, tracks, codecs).
- `Tests/StreamingTests/DurationScratchTests.swift` — the evidence harness.

Conclusion from findings: the mehd approach does **not** fix the duration. These changes should
be reverted or repurposed, not shipped as-is. (`head-parse` and the scratch test are useful
debugging tools — keep or delete at the next engineer's discretion.)

## Repro

### CLI (deterministic, no simulator needed)

The user's real file is a public torrent (info hash `d958e64d592dca7b91947cde6ad4e7942c3f3938`).
A **complete** copy lives at (temp, may have been cleaned):

```
/var/folders/sz/481762vd757_ff4593f9hyyr0000gn/T/opencode/mtp-dl/
  Meet the Parents 2000 REMASTERED 1080p BluRay HEVC x265 5.1 BONE.mkv   (2130538275 B, verified 1016/1016)
  Meet the Parents 2000 REMASTERED 1080p BluRay HEVC x265 5.1 BONE.mkv.torrent
  .d958e64d…verified
```

To reproduce the *hang* on a partial file: start a fresh partial download (or use a
`--stop-at`), then run `stream-test` against the same dir — it will print `loading asset…` and
hang on `asset.load(.duration)` (killed by the harness alarm after ~30 s).

Note: `stream-test`/`stream-play` start **two** `Torrent`s on the same directory
(`partial` then `stream`). This dual-torrent setup races over the same files/sidecar and is also
what the user suspected was interfering ("I was downloading it in multiple places"). If you
reproduce with these commands, keep that in mind — the app itself only runs one `Torrent`.

`torrent-cli head-parse <mkv>` is useful to confirm the declared duration:
`durationSeconds: 6459.198`.

### Simulator

`xtool dev run --network -u 00008130-001C4CA030A1401C`; simulator `NoFeedSocial iOS 26.3`
(UDID `6552DF1D-95CE-48E3-801F-8F80F0AA8D29`). Add the MTP magnet (copy to clipboard, the Add
sheet prefills it), wait for a partial download, tap the `.mkv` row → observe spinner + 8-min
duration. `TorrentLog.verbose` is enabled in the app, writes to stderr — capture with
`xcrun simctl launch --console-pty <udid> <bundleid>` (the app writes `stream req/served/finish`
lines).

## Current state of the environment

- CLI full download in the temp dir above is **complete and verified 1016/1016**
  (`torrent-cli verify` → `ok=1016 bad=0 missing=0`).
- The simulator app's data container was cleaned of the MTP torrent earlier in this session;
  `Documents/downloads/` now only has the `long30.mkv` smoke fixture. The app is currently
  terminated.
- Working tree: 4 modified files + 1 untracked test file (experimental mehd work). Not committed.
- No repo tests were broken during the session (`swift build --product torrent-cli` green;
  scratch suite isolated). Run `swift test` before committing anything.

## Ideas not yet tried / suggested next steps

The bug is: AVFoundation won't report total duration for a partial fMP4 from header hints.
Candidate directions (pick based on effort/impact):

1. **Accept the limitation, improve the UX**: since duration ≈ downloaded portion, AVPlayer's
   scrubber/seek is only meaningful within the downloaded region anyway (seeks beyond the
   frontier already wait via the loader). Options: (a) hide/repurpose the duration display in
   `PlayerView` until complete; (b) show the torrent's declared duration separately; (c) poll
   `AVPlayerItem.asset` and let duration grow as the download advances (verify AVPlayer
   re-evaluates it).
2. **Stop blocking the spinner**: the long hang is `asset.load(.duration)` waiting on the
   all-to-end request. If the loader finished probe/all-to-end requests at the current frontier
   instead of polling forever, playback would start promptly with the partial duration.
   Investigate why the loader keeps the request open (the "seek waits" contract in
   `TorrentStreamSession.serve`) and whether finishing at frontier breaks far-seek behavior
   (there is a hermetic test `farSeekServesOnceTargetVerifies` protecting it).
3. **`sidx`-style fake "end"**: could emit a placeholder sidx/last-fragment metadata in
   streaming mode so AVFoundation extrapolates a timeline to the declared duration. Risks:
   AVFoundation may reject mismatched sizes (we saw sidx sizes being validated against real
   moofs in some tests), and far seeks could seek into unverified virtual space. Low confidence.
4. **Confirm whether AVPlayer's duration updates as the download completes** — if yes, the
   8-min display is transient and only the spinner needs fixing; if no, the metadata approach
   (or UX approach #1) is required. This is the cheapest decisive test and should be run first
   (reproduce in simulator with a throttled or slow download while the player is open).

## Relevant docs / code

- `Sources/Streaming/TransmuxStreamSource.swift` — streaming vs precomputed modes, init/fragment
  generation, `reachesEOF`, `maybePrecomputeLayout`.
- `Sources/Streaming/Transmuxer.swift` — `MKVRemuxer`, `durationTicks: 0` at line 45,
  `initSegmentForStreaming`, sidx refs.
- `Sources/Streaming/MP4Muxer.swift` + `MP4Muxer+Fragments.swift` — boxes, `mehd`/`sidx` builders.
- `Sources/Streaming/TorrentStreamSession.swift` — resource loader delegate, `serve` loop
  (all-to-end/bounded/probe handling).
- `Sources/TorrentCore/Torrent+Streaming.swift` — `streamPriority`, `streamingAvailability`,
  `streamingRead`.
- `docs/implementation-notes.md` — duration notes; **2026-08-09 "correct MKV playback duration"**
  (the `16 000` video timescale fix) and the "durations must be 0" note are the most relevant.
- `docs/mkv-avplayer-transmuxer.md` — transmuxer design record.
- `Tests/StreamingTests/DurationScratchTests.swift` — this session's evidence.
- `Tests/StreamingTests/TransmuxStreamSourceTests.swift` — hermetic streaming tests (keep green).
