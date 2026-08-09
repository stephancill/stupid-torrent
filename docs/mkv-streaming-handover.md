# Handover — MKV streaming: HTTP server landed, need a vision check to confirm on-screen playback

Status: **needs a vision-capable model to confirm the simulator screen actually renders/advances video.** The byte-delivery side is proven working (VLC parses the MKV, decoders start, position advances). The remaining question is whether the video is visibly rendering in the SwiftUI `MKVPlayerView` — my screenshots (`simctl screenshot`) show a static frame and I cannot read images, so this needs human/vision eyes on the actual simulator.

## TL;DR for the next model

1. Read `docs/implementation-notes.md` (the two most recent entries: SIGPIPE fix, HTTP-server MKV fix) and `docs/mkv-streaming.md`.
2. Run the repro below (booted sim `NoFeedSocial iOS 26.3`, UDID `6552DF1D-95CE-48E3-801F-8F80F0AA8D29`).
3. **Look at the simulator window** (or a `simctl screenshot`) while the media.mkv player auto-opens. Answer: does video visibly play, or is it frozen on one frame?
4. If frozen, the likely culprit is VLCKit's iOS OpenGL vout (`VLCOpenGLES2VideoView doResetBuffers:` off-main-thread assertion) or the drawable wiring in `MKVPlayerView` — see [Outstanding questions](#outstanding-questions).

## Current code state

- **Committed** (`e473567`): `TorrentHTTPServer` (loopback HTTP/1.1, real Content-Length, byte ranges, keep-alive) + `MKVStreamSession` now points `VLCMedia(url:)` at the server instead of `VLCMedia(initWithStream:)`. `TorrentSeekableInputStream` feed-task EOF fix. 8 `TorrentHTTPServerTests`.
- **Committed** (`a51e2cb`): `SO_NOSIGPIPE` on all BSD sockets (app crashed with SIGPIPE during streaming + download).
- **Uncommitted working tree** (temporary smoke scaffolding, remove before committing):
  - `Sources/stupid_torrent_client/Views.swift`: env/arg-gated `smokeOpenMKVPlayerIfRequested()` auto-opens the first `.vlc` file of the torrent named `media.mkv` in a `fullScreenCover`.
  - `Sources/VLCBridge/MKVStreamSession.swift`: an `os.Logger` poll (every 1s) printing `VLC poll: pos=... dur=... state=... playing=...` under the smoke flag.

### Current simulator instance (as handed over)

- Sim `NoFeedSocial iOS 26.3` booted; app **installed and running** (PID 47823) with `--args -ST_MKV_SMOKE 1`. The `os.Logger` poll lines are NOT appearing for this instance — likely the installed build predates the logger change or the player didn't auto-present this particular launch. Do not trust this instance; **rebuild + reinstall + relaunch** with the exact commands below before judging the screen.
- Fixture verified present in the data container (survives reinstall via iOS data migration): `Documents/torrents/media.torrent`, `Documents/downloads/media.mkv` (3,855,858 B), `.ad4724f8cda714f27eedf155101aee71f5afa456.verified` (236/236 pieces).

## Why the HTTP server (background)

`VLCMedia(initWithStream:)` reports the stream size as `UINT64_MAX` (hardcoded in VLCKit's `open_cb`). VLC's Matroska demuxer needs a known size to compute duration and build the seek table, so with a stream it stalled at `dur=0`. `TorrentHTTPServer` gives VLC a real `Content-Length` + byte ranges over loopback, which VLC's HTTP input handles natively.

Proven working so far (all logged in prior sessions):
- VLC playing the **same media.mkv from a real file path** (`VLCMedia(path:)`): `dur=60023ms`, position advanced 782→6913ms across ticks.
- VLC over the HTTP server: `Duration=60023` parsed, h264+aac decoders started, `Received first picture`, `Stream buffering done`, and a direct poll of `player.time` advanced **89ms → 11325ms over 12s**.
- 8/8 `TorrentHTTPServerTests` pass (HEAD, full 200, 206 range, open-ended, suffix, 416, progressive, prioritize-follows-client).

## The open question

A later manual observation reported the **screen shows a static frame** ("frozen on the last frame") while the HTTP-server path is active. My `simctl screenshot` comparisons also show identical center pixels across 5-8s gaps. Two competing explanations:

1. **Playback IS advancing but `simctl screenshot` doesn't capture VLC's OpenGL layer.** VLCKit renders via `VLCOpenGLES2VideoView` (internal GLES view); simulator screenshots often miss GL-composited layers. Evidence *for* playback: position advancing via poll, `Received first picture`, `picture is too late to be displayed` warnings (frames being produced), `VoutDisplayEvent 'resize'`.
2. **Rendering is broken** by VLCKit's iOS vout in this environment. Evidence: the log shows `Modifying properties of a view's layer off the main thread is not allowed ... [VLCOpenGLES2VideoView doResetBuffers:]` — an off-main-thread layer mutation that could freeze the GL view even while the clock advances.

**A vision-capable model must disambiguate this**: watch the simulator, or capture video (`xcrun simctl io <udid> recordVideo --codec h264 /tmp/out.mp4`), and determine whether the test pattern (ffmpeg `testsrc`, colorful moving bars) actually moves.

## Repro

Prereqs: the fixture is already in the sim data container (survives app reinstall via iOS data migration):

```
DATA=$(xcrun simctl get_app_container 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 com.stupidtech.stupid-torrent-client data)
# Should show: Documents/torrents/media.torrent, Documents/downloads/media.mkv (3,855,858 B),
#   Documents/downloads/.ad4724f8cda714f27eedf155101aee71f5afa456.verified (236/236 pieces set)
ls "$DATA/Documents/torrents/" "$DATA/Documents/downloads/" | grep -i media
```

If the fixture is missing, rebuild it (needs `create-torrent` from `third-party/webtorrent/node_modules`):

```
# media.mkv: ffmpeg testsrc 640x360 @30fps 60s + sine audio, x264+aac, muxed to matroska (~3.7MB, 236x16KB pieces)
ffmpeg -y -v error -f lavfi -i "testsrc=size=640x360:rate=30:duration=60" -f lavfi -i "sine=frequency=440:duration=60" \
  -c:v libx264 -preset veryfast -b:v 800k -c:a aac -b:a 64k -f matroska media.mkv
# torrent: create-torrent (ESM): NODE_PATH=.../third-party/webtorrent/node_modules node make.mjs (see /tmp/partial-test/make.mjs)
# sidecar: UInt32 BE pieceCount(236) + bitfield all ones -> .<infoHash>.verified
# install: cp media.torrent -> $DATA/Documents/torrents/, cp media.mkv -> $DATA/Documents/downloads/
```

Build + launch (the smoke auto-opens the media.mkv player; `--args -ST_MKV_SMOKE` is required because `SIMCTL_CHILD_` env via `simctl launch` blocks the shell):

```
rm -f .build/.lock
xtool dev build --triple arm64-apple-ios-simulator
xcrun simctl install 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 xtool/stupid_torrent_client.app
xcrun simctl terminate 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 com.stupidtech.stupid-torrent-client 2>/dev/null
nohup xcrun simctl launch 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 com.stupidtech.stupid-torrent-client --args -ST_MKV_SMOKE 1 > /tmp/launch.log 2>&1 &
disown
```

Read the os.Logger poll (this DOES appear in `log show`, unlike `print`):

```
xcrun simctl spawn 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 log show --last 2m \
  --predicate 'subsystem == "com.stupidtech.stupid-torrent-client"' --style compact | grep "VLC poll"
# expect: pos=...ms dur=60023ms state=2 playing=true  (pos should climb ~1s/s if the clock advances)
```

Capture the screen / video for vision review:

```
xcrun simctl io 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 screenshot /tmp/screen.png
xcrun simctl io 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 recordVideo --codec h264 --force /tmp/playback.mp4   # Ctrl-C to stop
```

Expected if working: `VLC poll` pos climbs; the video shows a moving color-bar test pattern. If `pos` climbs but the screen is static → GL vout rendering issue (outstanding Q1). If `pos` is stuck → input/demux issue (Q3).

## Commands / gotchas (from this session)

- The QxR Backrooms torrent (`749c6111…`, 571 pieces, partial download in the sim) also auto-restores; its engine logs (`requesting 48 blocks`, `connecting to …`) flood stdout and can bury VLC lines — filter for `VLC poll` / `http:`.
- `swift test` sometimes hangs at the Swift Testing bundle-launch phase in this shell (stale `.build/.lock`). `rm -f .build/.lock` first; running individual tests via `swift test --skip-build --filter "Suite/test"` is reliable; `xcrun xctest` only runs XCTest, not Swift Testing tests.
- `SIMCTL_CHILD_ST_MKV_SMOKE=1 xcrun simctl launch …` blocks the shell → use `--args -ST_MKV_SMOKE 1` instead (the smoke gate checks both).
- `--console-pty` captures `print` but the launch blocks until killed; `log show` captures os.Logger + VLCKit `[DBG]` (when the `VLCConsoleLogger` is set) but not plain `print`.
- VLCKit's console logger (`VLCLibrary.shared().loggers = [VLCConsoleLogger()]`) writes to stdout; the `[DBG]`/`[ERR]` lines in earlier logs came from `--console-pty`. Default logger level filters to errors; set `.level = .debug` for demux detail.

## Outstanding questions / next steps

1. **(Primary) Does video visibly render/advance in the simulator?** If not, investigate the `VLCOpenGLES2VideoView doResetBuffers:` off-main-thread assertion. Options to try:
   - Attach the drawable before `player.play()` (already the case) and ensure the drawable `UIView` is in the window/has a frame before attaching (`VideoDrawableView.makeUIView` currently creates a bare `UIView`; consider giving it an explicit frame or using `.clipsToBounds`/opaque).
   - Check whether VLCKit needs the drawable attached on the main thread with a proper layer (`view.layer` vs the view itself — the header says "any UIView" on iOS).
   - Try `player.drawable = view.layer` if the view-based path is the problem (VLCKit macOS uses layers; iOS usually views).
   - If the vout is fundamentally broken in this VLCKit build on iOS 26 sim, consider rendering via `VLCMediaPlayer`'s snapshot (`lastSnapshot`) as a stopgap, or a different player backend.
2. **Seeking test on a partial file** (the real user scenario is the partially-downloaded QxR MKV): the server prioritizes requested ranges and blocks until verified; verify a seek-beyond-frontier stalls gracefully (buffering) and resumes, and that duration shows correctly for a partial file.
3. **End-of-file / `end of stream` handling**: earlier logs showed `end of stream` on the HTTP input thread after the full 200 was served; the bounded-206-lookahead change addressed the stall, but confirm a completed download still reaches `.ended` and doesn't hang at the last frame.
4. **Confirm `durationMs` populates in the UI** (the poller reads `media.length`; earlier it stayed 0 because time notifications don't fire — the poller should now surface it; verify the slider is enabled with the real duration).
5. **Cleanup before commit**: remove the smoke scaffolding from `Views.swift` and the `os.Logger` poll from `MKVStreamSession.swift` (and the `import MobileVLCKit`/`OSLog` added for it). Keep `TorrentHTTPServer` + tests.

## Test fixture reference

- `/tmp/partial-test/` — media.mkv, media.torrent, media.verified, make.mjs (fixture generator)
- `/tmp/mkv-fixture/` — earlier test.mkv (348 KB, the gate-0 render check that "worked" because it fit in one read)
- Info hash `ad4724f8cda714f27eedf155101aee71f5afa456`; single file `media.mkv`; 236 × 16 KiB pieces; 60.023 s.
- The real target: Backrooms 2026 1080p QxR (`749c611106b56f98de521168a5c5197cd5d13299`), 571 × 8 MiB pieces, ~4.78 GB single MKV (HEVC Main 10, E-AC-3 Atmos, 4 SRT subs), partially downloaded in the sim.
