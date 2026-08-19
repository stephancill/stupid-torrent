# AGENTS.md — stupid-torrent-client

## Project

A torrenting client for iOS that downloads from magnet links and `.torrent` files and can stream media files while they are still downloading. The BitTorrent engine is written from scratch in Swift, closely modeled on webtorrent (JS) and anacrolix/torrent (Go).

## Tech stack

- Swift 6 (strict concurrency, actors), SwiftUI, Network.framework (`NWConnection`), CryptoKit (`Insecure.SHA1`)
- SwiftPM (`swift-tools-version: 6.0`), iOS 17+ / macOS 14+ targets
- Built, signed, and released with the `stupid-app` CLI (no Xcode needed at release time)
- macOS `torrent-cli` executable product is the headless dev/test harness; `stupid-app` ignores executable products

## Agent rules (REQUIRED)

1. Before making any changes, read `docs/planning.md` and `docs/implementation-notes.md` to understand the plan and current state. Do not drift from the agreed architecture and phases without a deliberate, recorded decision.
2. Before committing, update `docs/implementation-notes.md` with a concise entry describing what changed and why.
3. Verify engine work before wiring UI (unless a task explicitly says otherwise): iterate with `swift test` against the hermetic harness (mock trackers + local webtorrent/aria2 seeder serving the Big Buck Bunny fixture — see `docs/planning.md` -> "Hermetic testing"), then use the live swarm as the final integration check via the `torrent-cli` harness.
4. Follow the global rules in `~/.config/opencode/AGENTS.md` (conventional commits, named function parameters, no comments unless asked, prefer periods over closing parentheses in numbered lists, etc.).

## Coding style

- Modern Swift: prefer actors/structs/enums/protocols over classes; avoid class hierarchies.
- Async/await throughout; no callbacks-only APIs at module boundaries.
- Prefer named function parameters over positional ones.
- No comments unless explicitly asked; prefer clear names.
- Never assume a dependency is available. The engine (`TorrentCore`/`Bencode`) is intentionally dependency-free (pure Foundation/Network/CryptoKit only). `Streaming` and the app may use AVFoundation/AVKit/SwiftUI.

## Commands

- Build all: `swift build`
- Run tests: `swift test`
- Build CLI: `swift build --product torrent-cli`
- Run CLI: `.build/debug/torrent-cli <command>`
- Build the iOS app (unsigned): `stupid-app build`
- Release to TestFlight/App Store: `stupid-app release archive` then `stupid-app release upload --wait`
- Deploy to a device: `stupid-app run --network --udid <udid>`

## Docs

- `docs/planning.md` — plan, decisions, architecture, phases, risks, test torrent
- `docs/implementation-notes.md` — running implementation log (update before every commit)
