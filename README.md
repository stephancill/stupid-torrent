# stupid-torrent

A torrenting client for iOS with streaming. Paste a magnet link or import a `.torrent` file, download files, and stream media while it's still downloading.

The BitTorrent engine is written from scratch in Swift, closely modeled on [webtorrent](https://github.com/webtorrent/webtorrent) (JS) and [anacrolix/torrent](https://github.com/anacrolix/torrent) (Go). No libtorrent, no C++.

## Features

- Magnet links and `.torrent` files
- HTTP(S) and UDP tracker announces
- Sequential + priority-window downloading (streaming-friendly)
- SHA-1 piece verification and fast-resume (verified-bitfield sidecar)
- AVPlayer streaming while downloading, with Picture-in-Picture
- Seeding (serves verified pieces back to peers)
- Foreground-only (iOS suspends background apps; audio keeps playing in background)

## Engine

Pure Swift, dependency-free (`Foundation`, `Network`-free BSD sockets, `CryptoKit`). Modules:

| Module | Responsibility |
|---|---|
| `Bencode` | bencode encode/decode, raw info-dict extraction for info-hash |
| `TorrentCore` | metainfo + magnet parsing, peer-wire protocol, trackers, sparse multi-file storage, sequential picker, torrent session, ut_metadata (BEP 9/10) |
| `Streaming` | `AVAssetResourceLoaderDelegate` feeding AVPlayer from verified pieces |
| `stupid_torrent_client` | SwiftUI app |

Supported BEPs: 3 (metainfo), 9 (ut_metadata), 10 (extensions), 12 (multitracker), 23 (compact peer lists). Deferred: DHT (BEP 5), µTP (BEP 29), protocol encryption, web seeds.

## Build & run

Built and deployed with [xtool](https://xtool.dev).

```sh
# Tests
swift test

# Headless macOS CLI harness (dev/test)
swift build --product torrent-cli
.build/debug/torrent-cli add Fixtures/big-buck-bunny.torrent
.build/debug/torrent-cli verify Fixtures/big-buck-bunny.torrent

# Run in the iOS simulator
xtool dev run --simulator

# Deploy to a device
xtool dev run --network -u <device-udid>
```

The `torrent-cli` executable product is ignored by xtool and is the headless dev/test harness. It validates the engine against the live Big Buck Bunny swarm before any UI work.

## Test torrent

Big Buck Bunny (webtorrent.io), info hash `dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c`, committed as `Fixtures/big-buck-bunny.torrent`. UDP-tracker-only, multi-file (mp4 + srt + jpg), pieces span file boundaries — a good real-world test.

## Project layout

```
Package.swift          SwiftPM (one app library product + torrent-cli executable)
xtool.yml + Info.plist app config
Fixtures/              test torrent
Sources/Bencode        bencode
Sources/TorrentCore    engine
Sources/Streaming      AVPlayer feeding
Sources/stupid_torrent_client  SwiftUI app
Tests/                 unit tests (bencode, metainfo, magnet, wire codec, metadata, bitfield)
docs/                  planning + implementation notes
```

## License

MIT (see `LICENSE`).
