# Handover - Native AVPlayer playback and controls for MKV

Date: 2026-08-10

Status: MKV playback through AVPlayer works by transmuxing Matroska to fragmented MP4. Partial-file far seeking also works. Native `AVPlayerViewController` timeline controls do not work correctly with the segmented partial-MKV seek architecture, so seekable MKVs currently use app-owned SwiftUI controls over an `AVPlayerViewController` whose native controls are hidden.

## Problem statement

Apple's AVFoundation does not demux Matroska. Passing an `.mkv` or `.mka` directly to `AVURLAsset`/`AVPlayerItem` fails as an unsupported format even when every contained codec is otherwise supported by AVFoundation.

The project therefore transmuxes MKV bytes into a virtual fragmented MP4 and serves that virtual file through `AVAssetResourceLoaderDelegate`. This makes native AVPlayer video/audio decoding possible without transcoding. The remaining problem is preserving fully native `AVPlayerViewController` behavior while the MKV is only partially downloaded, especially for far seeks.

The hard conflict is:

1. A far seek into an incomplete MKV must start a new virtual fMP4 at a Cues-selected keyframe because the intervening MKV data is unavailable.
2. That replacement fMP4 must rebase its decode and presentation timestamps near zero for AVFoundation to decode and display the new frames reliably.
3. `AVPlayerViewController` reads the replacement `AVPlayerItem`'s local clock directly for its native progress bar.
4. AVFoundation does not expose a supported API for giving `AVPlayerViewController` a separate global display clock while retaining a local decode clock.

As a result, the correct target frame can play while the native progress bar resets to the replacement item's local zero. Attempts to force the item itself onto the global movie timeline have broken frame updates or caused large clock jumps during playback transitions.

## Desired behavior

For an incomplete two-hour MKV:

- Playback should begin before the torrent completes.
- The UI should show the MKV's declared full duration.
- Seeking to 25% should prioritize the Cues-selected cluster near 25%, replace the current segment when ready, display the correct frame, and keep the progress bar at 25%.
- A later seek to 67% should supersede all older seek work, download only the newest target window, display the 67% frame, and keep the progress bar at 67%.
- Playback should resume after target buffering if it was playing before the seek.
- Normal MP4/MOV/M4A/etc. files should retain native AVKit controls.
- Ideally, Picture in Picture and the rest of `AVPlayerViewController` behavior should remain available.

## Important distinction: AVPlayer versus native AVKit controls

There are two different meanings of "native AVPlayer support" in this problem:

1. Native decoding and rendering with `AVPlayer`.
2. Native transport/timeline UI from `AVPlayerViewController`.

The first is working. H.264, HEVC, AAC, E-AC-3, AC-3, and ALAC in MKV are parsed and repackaged into ISO-BMFF samples, then decoded by AVFoundation. No codec transcoding occurs.

The second is only fully reliable when one stable `AVPlayerItem` owns one stable movie timeline. Partial MKV far seeking currently violates that assumption because each far seek creates a new local-timeline item.

## Why direct MKV playback is unavailable

AVFoundation has a fixed demuxer set. Matroska is not supported on the tested macOS/iOS 26.3 environment. This is independent of codec support:

- HEVC and H.264 decode when carried in MP4.
- AAC, E-AC-3, and AC-3 decode when carried in MP4.
- The same streams inside MKV are rejected by AVFoundation before codec decode begins.

Empirical verification is recorded in `docs/mkv-avplayer-transmuxer.md`. MP4 fixtures decode through `AVAssetReader`; equivalent MKV fixtures fail with AVFoundation error `-11828` (`Cannot Open` / unsupported format).

There is no public AVFoundation plug-in API for adding a Matroska demuxer. The practical choices are:

- Transmux MKV to an AVFoundation-supported container.
- Bundle a separate media stack such as VLC/libavcodec.
- Write a custom sample-buffer player instead of using AVPlayer.

This project chose transmuxing to keep the app small, native, and free of a large binary media dependency.

## Current architecture

```text
Torrent verified bytes
        |
        v
TorrentStreamSourceAdapter
        |
        v
TransmuxStreamSource
  - parses EBML/Matroska head
  - selects supported default video/audio tracks
  - reads Cues
  - converts clusters to fMP4 fragments
        |
        v
TorrentResourceLoaderDelegate
  serves stupidtorrent://... as a virtual fMP4
        |
        v
AVURLAsset -> AVPlayerItem -> AVPlayer
        |
        +-- normal/native AVKit controls for non-segmented media
        |
        +-- app-owned global timeline controls for segmented MKV playback
```

Relevant entry points:

- `Sources/Streaming/TorrentStreamSession.swift`
- `Sources/Streaming/TransmuxStreamSource.swift`
- `Sources/Streaming/Transmuxer.swift`
- `Sources/Streaming/MatroskaReader.swift`
- `Sources/Streaming/MP4Muxer.swift`
- `Sources/Streaming/MP4Muxer+Fragments.swift`
- `Sources/stupid_torrent_client/Views.swift`

## Virtual fMP4 modes

`TransmuxStreamSource` has two materially different modes.

### Complete/precomputed mode

When the whole MKV is verified:

- The source scans cluster headers and computes every fragment's exact size.
- It emits an init segment with a `sidx`.
- Virtual byte offsets and total content length are exact.
- Fragments can be generated directly by virtual offset.

This is the closest architecture to a normal stable AVPlayer asset.

### Partial/sequential mode

When the MKV is incomplete:

- The head is parsed from a verified prefix.
- Future cluster sizes and sample counts are not globally known.
- There is no complete `sidx` or exact future virtual byte layout.
- Fragments are generated sequentially as MKV clusters become verified.
- The virtual content length is an estimate (`remaining MKV bytes + 128 KiB margin`).

This mode is what enables playback before 100% download, but it is also why a far seek cannot simply request a future fragment from one stable virtual asset.

## Current far-seek design

The partial-MKV far-seek flow is implemented by `TorrentSeekingPlayer`, `TorrentStreamSession`, and `TransmuxStreamSource.prepareForSeek`.

1. The UI calls `AVPlayer.seek` with global movie time.
2. `TorrentSeekingPlayer` intercepts all public seek overloads.
3. The previous seek generation is canceled; the latest seek owns the pending playhead.
4. A fresh `TransmuxStreamSource` is created for the requested target.
5. `prepareForSeek` loads Matroska Cues if necessary.
6. It chooses the retained video track's cue at or before the requested movie time.
7. The torrent prioritizes the Cues range, then the target cluster's MKV byte range.
8. The source waits for the target cluster to verify.
9. A new `MKVRemuxer` starts at that cluster and rebases its sample timeline to local zero.
10. A unique `AVURLAsset` and `DeclaredDurationPlayerItem` are created.
11. The player replaces its current item and seeks to `global target - cue timeline offset` inside the local item.
12. `TorrentSeekingPlayer.currentTime()` reports `local item time + cue timeline offset` to app-owned callers.
13. Playback resumes if the original seek began while playing.

The item must be unique per seek. Reusing the original asset URL or source allowed AVFoundation caches to keep rendering the old frame.

## Why the replacement segment uses a local clock

The new fMP4 starts at a keyframe somewhere in the middle of the MKV. Its samples are emitted with decode timestamps beginning near zero. The original Matroska cluster timestamp is subtracted in `MKVRemuxer` through `presentationTimeOffset`.

This is deliberate. Earlier experiments exposed global sample/item time directly. The progress bar moved, but AVFoundation continued rendering the previous frame or failed to transition cleanly to the new decoder timeline.

The working invariant is:

- AVFoundation item/sample clock: local to the current Cues segment.
- App/movie clock: local clock plus the segment's global Cues offset.

`TorrentSeekingPlayer.currentTime()` implements the second clock. `AVPlayerViewController` does not consistently use that override for its progress UI; it observes the current `AVPlayerItem` and therefore sees only the first clock.

## Native progress-bar failure

The original UI used a normal `AVPlayerViewController` with `showsPlaybackControls = true`.

After a successful far seek:

- The target frame was correct.
- `TorrentSeekingPlayer.currentTime()` reported the requested global movie time.
- The replacement `AVPlayerItem.currentTime()` reported a few local seconds.
- AVKit's elapsed-time label and slider reset to those local seconds.

This is not fixed by overriding `AVPlayerItem.duration`. `DeclaredDurationPlayerItem` successfully makes native controls show the full MKV duration, but duration and current time are separate concerns. AVKit still reads the current item's local playback time.

There is no public `AVPlayerViewController` hook for:

- Supplying a custom current-time value.
- Applying an arbitrary display offset to the scrubber.
- Intercepting its internal observation of `AVPlayerItem.currentTime()`.
- Mapping native slider positions through an application-owned timeline.

Private AVKit view traversal or KVC-based modification is not acceptable.

## Current working UI

Seekable/segmented MKV playback uses `SegmentedPlayerView` in `Sources/stupid_torrent_client/Views.swift`.

- The underlying renderer is still `AVPlayerViewController`.
- `showsPlaybackControls` is false for this path.
- A SwiftUI overlay provides Close, back 10 seconds, Play/Pause, forward 10 seconds, a slider, elapsed time, and remaining time.
- The slider reads `player.currentTime()`, which is the global clock from `TorrentSeekingPlayer`.
- The slider emits one seek when scrubbing ends instead of emitting many intermediate native AVKit seek callbacks.
- AVFoundation remains on its local decode timeline.
- Non-segmented media continues to use native AVKit controls.

Simulator verification against the active Meet the Parents partial torrent:

- First custom seek landed at approximately 22%.
- It advanced from `23:52` to `24:04` without resetting.
- A second seek landed at approximately 67%.
- It advanced to `1:12:15` without reviving the first item or resetting the bar.

This is the current known-good behavior.

## Related concurrency and picker bugs already fixed

These are independent of the native progress-bar limitation but are essential to correct repeated seeks.

### Stale asynchronous seek replacement

Native AVKit scrubbing emits multiple `seek` calls while the thumb moves. An older seek could finish target buffering after a newer seek and replace the player item with the obsolete target.

`TorrentSeekingPlayer` now:

- Assigns each seek a generation.
- Cancels older preparation.
- Checks generation after suspensions and completion callbacks.
- Keeps only the latest pending playhead.
- Preserves the original playing/resume intent across replacement seeks.

### Completed first seek absorbing the second seek

After a first far seek completed, AVFoundation's estimated duration for that local segment could make a later global target appear to be locally seekable. The old implementation then tried to walk the first sequential transmux source through unavailable intervening MKV bytes.

Every segmented partial-MKV user seek now prepares a fresh Cues-based source. It does not use the current asset's estimated duration to absorb later global seeks.

### Stale torrent priority windows

Every seek used to add another high-priority piece window. Old targets remained in `PiecePicker.priority`, so the torrent could download obsolete target windows before the newest seek.

`PiecePicker.replacePriorities` and `Torrent.streamPriority` now replace old jump priorities with the latest jump window. Ordinary low-priority sequential lookahead remains additive.

## Approaches tried and rejected

### 1. Pass MKV directly to AVPlayer

Result: unsupported container (`-11828`). Codec support does not add Matroska demux support.

### 2. Keep one partial fMP4 and let the resource loader jump

Problem: future virtual fragment offsets and sizes are unknown until cluster structure is read. A partial source has no complete deterministic byte layout or `sidx`. Generating a fragment at a far virtual offset would otherwise require walking and sizing all intervening clusters.

### 3. Override only `AVPlayerItem.duration`

Result: useful but incomplete. It fixes the displayed total duration. It does not alter AVFoundation's internal seekable partial-asset timeline or the replacement item's local current time.

This remains in production as `DeclaredDurationPlayerItem`.

### 4. Put declared durations in `mvhd`/`tkhd`/`mdhd`

Result: AVFoundation sums declared track/movie duration with fragment durations and can report approximately double duration. Fragmented init durations remain zero in the working muxer.

### 5. Add `mehd`

Result: ignored for the required partial-loader duration behavior.

### 6. Use `sidx` as a duration hint

Result: AVFoundation uses actual readable fragment durations for total duration. Synthetic or inflated `sidx` durations did not override that behavior. `sidx` remains useful for exact complete-file byte seeking.

### 7. Expose global timestamps/current time directly in the replacement item

Result: the progress bar moved, but the displayed frame remained unchanged or the decoder did not transition correctly. The item/sample decode timeline must remain local for the current segment architecture.

### 8. Reuse the original source or URL for seek assets

Result: AVFoundation cache identity could preserve old media state. Every seek asset now receives a unique URL and an isolated transmux source/delegate.

### 9. Add fMP4 `edts`/version-1 `elst` mapping

Attempt: add an empty edit covering movie time before the cue, followed by a media edit mapping local samples to the global movie timeline.

Initial result: the replacement `AVPlayerItem` could report a global-looking time in a player-level test.

Simulator result: unstable and rejected. During the paused-seek-to-playing transition, AVFoundation reapplied the edit and the visible clock jumped from `1:15` to `10:06` within five seconds. This also reintroduced uncertainty about whether the displayed time and decoded frame referred to the same movie position.

The edit-list code was removed. Do not restore it without a regression that covers paused seek, item replacement, first-frame decode, playback start, and at least several seconds of clock advancement on iOS.

### 10. Finish an all-to-end loader request at an arbitrary byte cap

Result: AVFoundation interpreted the response as EOF and stopped playback at the first fragment. Playback all-to-end requests must remain open until cancellation, a deliberate current-frontier probe completion, or real source EOF.

## Duration-specific AVFoundation findings

For fragmented MP4 served through the resource loader:

- AVFoundation derives raw asset duration from readable fragments.
- A partial asset therefore reports only the currently readable fragment duration.
- Header-only duration hints do not provide a reliable full partial-file timeline.
- Holding duration-related all-to-end requests open at the verification frontier causes long startup spinners.
- The loader now finishes MKV all-to-end probes at the current readable frontier, while bounded seek requests still wait for target verification.
- `DeclaredDurationPlayerItem.duration` supplies the full Matroska-declared duration to app/native UI where possible.

The detailed empirical matrix is in `docs/handover-mkv-duration-spinner.md`.

## Cues requirements and limitations

Partial far seeking requires an index from movie time to MKV cluster offset.

- `MatroskaParser` reads the Cues location from `SeekHead`.
- `prepareForSeek` loads Cues on demand.
- Cue positions are filtered for the retained default/enabled video track.
- The selected cluster must contain a keyframe for that track.

Current capability behavior:

- Partial MKV with Cues: segmented far seeking enabled.
- Partial MKV without Cues: segmented far seeking disabled; controls are limited to the readable timeline.
- Complete MKV: a precomputed fragment layout exists, but `prepareForSeek` still fundamentally uses Cues. The current `supportsFarSeeking` condition also returns true for a complete layout, so complete Cues-less seek behavior deserves a dedicated follow-up test.

## Codec and track scope

Current transmuxed codecs:

- Video: H.264, HEVC.
- Audio: AAC, E-AC-3, AC-3, ALAC.
- One enabled/default track per media type is retained.

Current omissions:

- Embedded subtitles.
- Opus, Vorbis, FLAC, DTS.
- AV1-in-MKV.
- WebM and AVI containers.

The default-track selection matters for the real MTP file, which has a default 5.1 mix plus two commentary tracks. Emitting all supported audio tracks made AVFoundation mix them simultaneously.

## Resource-loader behavior that must remain intact

`TorrentResourceLoaderDelegate` handles three request classes:

- All-to-end playback requests: stream verified chunks and remain open until source exhaustion/cancellation; MKV duration probes may finish at the current frontier after serving data.
- Bounded requests: wait for requested bytes to verify instead of finishing empty.
- Zero-length probes: serve what is available and finish so AVFoundation can issue another request.

Loading tasks are tracked by `AVAssetResourceLoadingRequest` identity and canceled when AVFoundation cancels the request or a seek invalidates an old asset.

Do not finish a bounded far-seek request empty. AVPlayer treats that as failure and returns to the previous buffered position.

## Test coverage

Current full suite: 71 tests across 15 suites.

Most relevant tests in `Tests/StreamingTests/TransmuxStreamSourceTests.swift`:

- `streamsSequentiallyAsBytesVerify`
- `farSeekServesOnceTargetVerifies`
- `partialDurationProbeFinishesAtCurrentFrontier`
- `farSeekThroughPlayerRequestsTarget`
- `latestFarSeekSupersedesPendingSeek`
- `completedFarSeekDoesNotAbsorbNextSeek`
- `cuesLessPartialSourceDisablesFarSeeking`
- `virtualFileMatchesFullRemux`

Most relevant picker test in `Tests/TorrentCoreTests/TorrentCoreTests.swift`:

- `replacingPrioritiesDropsEarlierSeekWindow`

The tests prove source bytes, seek ownership, playhead translation, and picker replacement. They do not fully prove native `AVPlayerViewController` UI behavior because that UI reads private/internal player-controller state. Simulator interaction remains a required integration gate.

## Real-world reproduction asset

Torrent:

```text
Meet the Parents 2000 REMASTERED 1080p BluRay HEVC x265 5.1 BONE
```

Known facts:

- MKV size: 2,130,538,275 bytes.
- Torrent pieces: 1,016 at 2 MiB.
- Declared duration: approximately 6,459.2 seconds (107:39).
- Video: HEVC 1080p, approximately 23.976 fps.
- Audio: default AAC 5.1 plus two commentary tracks.
- Info hash: `d958e64d592dca7b91947cde6ad4e7942c3f3938`.

The active iOS simulator has this torrent/download state and has been used for all final integration checks.

## Simulator environment

Preferred simulator:

```text
Name: NoFeedSocial iOS 26.3
UDID: 6552DF1D-95CE-48E3-801F-8F80F0AA8D29
Bundle ID: com.stupidtech.stupid-torrent-client
```

Build/install/launch:

```bash
swift test
xtool dev run --simulator --udid 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 --no-attach --no-logs
xcrun simctl launch 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 com.stupidtech.stupid-torrent-client
```

Useful inspection:

```bash
idb ui describe-all --udid 6552DF1D-95CE-48E3-801F-8F80F0AA8D29
xcrun simctl spawn 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 log show --last 5m --style compact --predicate 'process == "stupid_torrent_client"'
```

The app enables `TorrentLog.verbose`; resource-loader messages are written to stderr. Unified AVKit/CoreMedia logs are useful for confirming item replacement, first-frame enqueue, seek completion, and loader cancellation.

## Current worktree state

At handover time, the repeated-seek and custom-control changes are in the working tree and are not committed.

Expected modified implementation/test files include:

- `Sources/Streaming/TorrentStreamSession.swift`
- `Sources/TorrentCore/PiecePicker.swift`
- `Sources/TorrentCore/Torrent+Streaming.swift`
- `Sources/stupid_torrent_client/Views.swift`
- `Tests/StreamingTests/TransmuxStreamSourceTests.swift`
- `Tests/TorrentCoreTests/TorrentCoreTests.swift`
- `docs/implementation-notes.md`

Verification completed before this handover:

- `swift test`: 71 tests passed.
- `xtool dev run --simulator ...`: build and install passed.
- First custom seek in the live partial MKV: 22%, advancing `23:52` to `24:04`.
- Second custom seek: 67%, advancing to `1:12:15` without resetting.

## If fully native controls are still required

Do not start by modifying `AVPlayerViewController` internals. The viable direction is to eliminate replacement local-timeline items and present AVFoundation with one stable global-timeline asset.

Potential research directions:

### 1. Build a stable global virtual fMP4 layout before payload download

Requirements:

- Know every fragment's virtual byte offset and size.
- Know each fragment's global decode/presentation time.
- Generate any requested fragment independently from its MKV cluster.
- Keep one asset URL and one `AVPlayerItem` for the whole movie.

The blocker is fragment size: Matroska Cues provide time and cluster position, but not enough per-cluster sample/mdat sizing information for this muxer's exact virtual fMP4 offsets. A structural scan currently requires reading cluster headers across the full file. In BitTorrent terms, sparse structural scanning may require verifying many pieces spread throughout a multi-gigabyte file.

Research question: can fragment format be redesigned so virtual fragment slots have fixed sizes or another deterministic mapping that does not require scanning every intervening cluster? Padding/slotting would increase virtual size and must still be accepted by AVFoundation.

### 2. Prefetch a sparse structural index

Use Cues to prioritize pieces containing each cluster header, scan only enough bytes to derive sample counts and payload sizes, then build the complete layout before enabling full native seeking.

Tradeoffs:

- Torrent piece granularity may make "small header reads" expensive.
- Cues may not list every cluster.
- Lacing and block groups can require parsing more than a tiny fixed header.
- Startup and network cost could approach downloading a substantial portion of the file.

### 3. Generate a real segmented streaming presentation

Investigate HLS/fMP4 playlists where each Cues segment is a media segment on one declared timeline. AVPlayer is designed for segment transitions and may preserve native controls without item replacement.

Open questions:

- Whether a custom-scheme/resource-loader-backed dynamic HLS presentation is accepted.
- How to expose the complete duration before all media segments exist.
- Whether arbitrary on-demand Cues segments can be introduced without discontinuity artifacts.
- Whether local/offline HLS changes App Store/network behavior or caching assumptions.

This is likely the most promising native-controls direction, but it is a separate streaming architecture rather than a small patch.

### 4. AVMutableComposition with per-segment assets

Investigate whether a composition can map local segment media times onto global composition time while replacing or lazily inserting unavailable segments. AVFoundation compositions are generally expected to be static, and dynamic insertion during playback may invalidate the item, but this has not been exhaustively tested here.

### 5. Accept app-owned controls

The current solution is the smallest reliable architecture:

- Native AVFoundation decode/render remains.
- Global and local clocks remain explicitly separated.
- Repeated partial-file seeks work.
- UI behavior is under application control.

The main follow-ups are UI polish, control auto-hiding, accessibility, and restoring an explicit Picture in Picture action if required.

## Native-controls investigation acceptance test

Any future claim that native AVKit controls work must pass all of these on the iOS simulator with an incomplete MKV:

1. Start playback from the verified prefix.
2. Confirm full declared duration is visible.
3. Seek to 25% while playing.
4. Confirm target cluster pieces are prioritized without downloading the intervening range.
5. Confirm a new target frame is visibly decoded.
6. Confirm native elapsed time and slider remain near 25% after item/segment transition.
7. Let playback run for at least 10 seconds; clock must advance at 1x without a delayed jump.
8. Seek to 67% after the first seek has fully completed.
9. Confirm the second frame replaces the first and playback resumes.
10. Confirm old seek delegates/tasks are canceled and stale priority windows are gone.
11. Repeat a rapid scrub that emits multiple seeks; only the final target may replace media.
12. Verify pause/resume, back/forward, audio, rotation/fullscreen, and Picture in Picture.

A test that only checks `AVPlayer.currentTime()` is insufficient. A test that only checks `AVPlayerItem.currentTime()` while paused is also insufficient. The rejected edit-list approach passed a narrow item-time assertion and still jumped badly when playback began.

## Recommended next action

Keep the app-owned segmented controls unless fully native controls are a product requirement worth a larger architecture change.

If native controls are required, prototype HLS-style segmentation or a stable precomputed virtual layout in an isolated harness using `Fixtures/mkv/long30.mkv`. Do not alter the production player until the prototype passes the full acceptance test above, especially the paused-to-playing clock transition and a second completed far seek.

## Related documents

- `docs/planning.md` - project architecture and streaming decisions.
- `docs/implementation-notes.md` - chronological implementation and verification log.
- `docs/mkv-avplayer-transmuxer.md` - original transmuxer design and codec feasibility evidence.
- `docs/handover-mkv-duration-spinner.md` - detailed partial-fMP4 duration/spinner investigation.
- `docs/mkv-streaming-handover.md` - superseded VLCKit rendering handover and historical simulator evidence.
- `docs/mkv-streaming.md` - superseded VLC-based MKV streaming architecture and historical context.
