---
name: stupid-torrent-debug
description: Debug the stupid-torrent iOS app in the simulator and use the torrent-cli harness. Use when working on this repo and you need to check app/download state in the simulator, read app logs, diagnose download/stall/resume issues, run the engine headlessly via torrent-cli, or set up hermetic seeding with aria2. Triggers include "check the app state", "why isn't it downloading", "resume", "stream-test", "simulator", "torrent-cli", "stall".
---

# stupid-torrent debugging

This repo: an iOS torrent client (xtool/SwiftPM) with a from-scratch Swift BitTorrent engine (`Bencode`, `TorrentCore`, `Streaming`) and a macOS `torrent-cli` headless harness. See `docs/planning.md` and `docs/implementation-notes.md`.

## Simulator

Preferred simulator: `NoFeedSocial iOS 26.3`, UDID `6552DF1D-95CE-48E3-801F-8F80F0AA8D29`.

```sh
xcrun simctl boot 6552DF1D-95CE-48E3-801F-8F80F0AA8D29   # boot if needed
open -a Simulator                                         # show it
xtool dev run --simulator -u 6552DF1D-95CE-48E3-801F-8F80F0AA8D29 --no-attach --no-logs   # build + install (~5s after build)
xcrun simctl terminate <udid> com.stupidtech.stupid-torrent-client
xcrun simctl launch <udid> com.stupidtech.stupid-torrent-client
xcrun simctl io <udid> screenshot /tmp/app.png
```

Do NOT sleep 45s+ after `xtool dev run` — it installs in ~5s. Check the log (`tail -2`) briefly, then proceed.

### Reinstall does NOT reset the download

iOS migrates the app's data container on update (container UUID changes, Documents is preserved). If a relaunch restarts from 0%, it is a resume bug (the `.verified` sidecar has 0 bits), not the reinstall. The sidecar-resume bug (`completePiece` not marking `storage.verified`) was fixed — do not reintroduce.

## Check app state

```sh
skills/stupid-torrent-debug/scripts/check_app_state.sh <udid> [bundle-id]
```

Manually:

```sh
DATA=$(xcrun simctl get_app_container <udid> com.stupidtech.stupid-torrent-client data)
ls -la "$DATA/Documents/torrents/"     # restored .torrent files (persistence)
ls -la "$DATA/Documents/downloads/"    # data files + .<hash>.verified sidecar
```

- Sidecar format: `UInt32 BE pieceCount` + bitfield bytes (MSB first). Count set bits:
  `python3 -c "import struct;d=open('<sidecar>','rb').read();print(sum(bin(b).count('1') for b in d[4:]))"`
- To test restore: copy a `.torrent` into `$DATA/Documents/torrents/`, terminate + relaunch. The app's `TorrentStore.restore()` picks it up and resumes from the sidecar.

## App logs

Engine verbose logging is on in the app (`TorrentLog.verbose = true` in the App init). Prints go to the unified log:

```sh
xcrun simctl spawn <udid> log show --last 5m --predicate 'processImagePath CONTAINS "stupid_torrent"' --style compact
```

Filter for `announce`, `connected to`, `unchoked`, `piece ... verified`, `dropped`, `bann`. A stalled download usually shows no outgoing peer connections (`lsof -nP -iTCP -a -p <pid>`).

## torrent-cli

```sh
swift build --product torrent-cli      # NOTE: `xtool dev run` can clean .build; rebuild after
.build/debug/torrent-cli add <file.torrent|magnet:...> [--dir <dir>] [--stop-at <bytes>] [--peer host:port] [--verbose]
.build/debug/torrent-cli verify <file.torrent> [--dir <dir>]      # SHA-1 per piece, ok/bad/missing
.build/debug/torrent-cli tracker <announce-url> --info-hash <hex40>   # probe a tracker
.build/debug/torrent-cli stream-test <file.torrent> [--peer] [--seed-until]  # loads AVAsset duration headless
```

- `stream-test` loads the asset (duration/playable) headlessly — fine. AVPlayer *playback* does NOT run headless in the CLI (no main run loop), so use the simulator for playback timing.
- `--stop-at` breaks on *verified* bytes (not received), and can overshoot (500ms poll + fast loopback).
- `--peer` injects a peer address directly (no trackers needed) — the deterministic hermetic path.

## Hermetic testing

Use `aria2c` (installed) as a seeder, with tracker-less torrents so only the injected peer is used:

```sh
aria2c --enable-dht=false --bt-enable-lpd=false --check-integrity=true \
  --seed-ratio=0.0 --seed-time=86400 --listen-port=<port> --dir=<seed-dir> \
  --file-allocation=none <torrent>
.build/debug/torrent-cli add <torrent> --dir <dl> --peer 127.0.0.1:<port>
```

- `aria2c` seeding gotchas: `--seed-time=0` stops seeding immediately (use `--seed-time=86400`); pre-existing files need `--check-integrity=true`; it errors on "control file does not exist" without `--allow-overwrite=true`.
- Make a tracker-less torrent by stripping `announce`/`announce-list` from a webtorrent-created `.torrent` (see the bencode strip used during development). Tracker-less => the engine won't announce; only `--peer` is used => deterministic.
- Make test media with ffmpeg (`/opt/homebrew/bin/ffmpeg`): `ffmpeg -f lavfi -i testsrc=size=1280x720:rate=30:duration=30 -f lavfi -i sine=frequency=440:duration=30 -c:v libx264 -preset veryfast -b:v 2000k -c:a aac -movflags +faststart test.mp4`.
- webtorrent-cli can create torrents but crashes on `seed` under node 22 — use aria2 for seeding.
- Verify a fully-downloaded hermetic result with `verify` -> `ok=N bad=0 missing=0`, and compare file sizes to the expected lengths.

## Live swarm (Big Buck Bunny)

- Info hash `dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c`, fixture `Fixtures/big-buck-bunny.torrent`, magnet with `tr=udp://explodie.org:6969` + `tr=udp://tracker.opentrackr.org:1337`.
- Trackers: `explodie.org:6969` reliable; `tracker.opentrackr.org:1337` flaky (intermittent UDP timeouts) — a failed announce is normal, not a bug.
- Announce cadence is capped at 60-90s. A temporary download stall is usually a tracker/peer gap, not a code bug — it self-recovers on the next announce.
- Some public-swarm peers are poisoners (corrupt blocks). On SHA-1 failure the engine requeues and bans repeat offenders (>=2 failures) — do not make banning more aggressive.

## Gotchas (don't "fix" these)

- **BSD sockets are intentional**: `NWConnection`/Network.framework is sandbox-blocked in the dev shell (never reaches `.ready`); the engine uses raw BSD sockets (`BSD.swift`). Reverting to NWConnection will break dev testing. Works on iOS too.
- **Data slices**: `Data.dropFirst()`/`dropLast()` return a slice with non-zero `startIndex`. 0-based indexing (`data[0]`) and `subdata(in:)` on slices trap/misbehave. Copy first (`Data(body.dropFirst())`) or use `startIndex`-relative access (`int32(at:)`). Several real bugs came from this.
- `AVPlayerViewController` does not exist in this macOS SDK (host `swift build`); iOS-only code must be `#if os(iOS)` guarded (PiP, `fullScreenCover`, AVPlayerViewController). Use SwiftUI `VideoPlayer` for the macOS variant.
