# Handover — µTP (BEP 29) transport implementation

Status: **in progress, not committed.** The µTP files are uncommitted working-tree changes, plus a small `UDPSocket` addition. Handing off for a developer to continue, fix, and land.

## Goal

Add µTP (BEP 29) so the client can reach peers that only accept µTP. This is the remaining transport gap: MSE/PE (BEP 10) and DHT (BEP 5) are landed, but some peers (and WebTorrent's advantage on swarms like The Odyssey) use µTP.

## Uncommitted working tree (do not lose)

```
Sources/TorrentCore/UTP.swift           153 lines   wire codec (header, extensions, packet types)
Sources/TorrentCore/UTPConnection.swift 338 lines   per-connection state machine
Sources/TorrentCore/UTPTransport.swift  135 lines   UDP socket, connection demux, retransmit ticker
Sources/TorrentCore/BSD.swift           (diff)       UDPSocket.receiveFrom(timeout:) returns sender addr
```

These are NOT committed and NOT in `git log`. They do not build cleanly yet (see **Known bugs**). Do not `git add` them blindly — inspect first.

Already committed (done before this handover):
- `b8274e7` — verbose diagnostics for the block-request pipeline
- `42fbdcb` — MSE/PE protocol encryption (BEP 10)
- `ca8be50` — DHT peer discovery (BEP 5) + bootstrap hardening

## Architecture so far

Mirrors libutp (`utp_internal.cpp`) with a clean actor split:

- `UTP` — packet constants + codec. Header is 20 bytes: `ver_type` (4-bit type, 4-bit version=1), `ext`, `connid`, `tv_usec`, `reply_micro`, `windowsize`, `seq_nr`, `ack_nr`. Packet types: `ST_DATA=0`, `ST_FIN=1`, `ST_STATE=2`, `ST_RESET=3`, `ST_SYN=4`. Extensions: `SACK=1`, `extension_bits=2`, `socket_read=3`, `socket_write=4`.
- `UTPConnection` (actor) — seq/ack tracking (16-bit wrap), send buffer, receive reorder buffer, retransmit via `nudge()`, SYN/STATE/FIN/RESET handling.
- `UTPTransport` (actor) — one shared `UDPSocket`; demuxes incoming datagrams to connections keyed by `(host, port, connid)`; runs a 250ms ticker calling `connection.nudge()` for retransmit.

## Connection ID scheme (verified against libutp)

From `utp_initialize_socket` and the SYN/STATE paths in libutp:

- **Initiator**: `utp_initialize_socket(..., need_seed=true, seed=0, recv=0, send=1)` → `recvID = seed`, `sendID = seed + 1`. The SYN packet carries `connid = recvID` (= seed).
- **Responder**: on receiving SYN with connid `id`: `utp_initialize_socket(..., need_seed=false, seed=id, recv=id+1, send=id)` → `recvID = id + 1`, `sendID = id`. Reply STATE carries `connid = sendID = id`.

So both sides send with their `sendID`; the IDs differ by 1 (initiator sends seed, responder replies seed; then data flows with sendID = seed+1 vs seed). See `utp_internal.cpp:2748` (initiator) and `:2992` (responder).

## Known bugs to fix first

1. **`UTPTransport.start()` uses a raw `Thread` to run `receiveLoop()`**, but `receiveLoop`/`handleIncoming` are actor-isolated. A raw `Thread` cannot enter an actor's isolated methods — the loop likely never processes datagrams (interop test showed the peer *received* our SYN but we never handled its STATE reply). **Fix**: run the receive loop as a detached `Task` (`Task.detached`/`Task { ... }` with `nonisolated` socket reads), or make the socket read + dispatch a `nonisolated` path that hops into the actor. The `UDPSocket` is `@unchecked Sendable`, so a detached task reading it and calling `await connection.receive(packet:)` is the intended design.

2. `UTPConnection` `receive(packet:)` is `public` but called from the transport — verify access levels after the actor/task refactor.

3. Several leftover placeholder/dead members (`flush()` overlaps `nudge()`, unused `markConnected`, unused `readBytesAvailable`, unused `packetSource` remnants). Clean up.

4. Confirm `UTP.Packet` Sendable conformance works for the actor-boundary passing (it was added; re-verify after the transport fix).

5. `UDPSocket.receiveFrom` casts `sin_addr.s_addr` bytes to an IP string — verify byte order (it builds `a.b.c.d` from the 4 raw bytes; on Darwin `s_addr` is network byte order already, so this is correct, but confirm in a test).

## Testing

### Interop test (essential)

We have `utp-native` (the Node binding to **libutp**, the BEP 29 reference implementation) at:

```
third-party/webtorrent/node_modules/utp-native
```

It loads (`node -e "require('utp-native')"` succeeds). Use it as the independent reference peer — this is how MSE/PE was validated.

A basic loopback test was started but not completed (blocked by bug #1):
- Node server: `utp.createServer(...)` listening on a UDP port, echoes data back.
- Swift initiator: `UDPSocket` + `UTPTransport` + `UTPConnection`, sends SYN, waits for STATE, sends a payload, reads the echo.

When re-running, set `NODE_PATH=/Users/stephan/environments/personal/pus/stupid-torrent-client/third-party/webtorrent/node_modules` so `require('utp-native')` resolves. The Swift initiator currently timed out (`FAILED: timeout`) because the receive loop never ran (bug #1) — the Node server log showed `libutp: connection from 127.0.0.1:...`, proving our SYN was well-formed.

### Unit tests to add (follow `Tests/TorrentCoreTests`)

- `UTP.Packet` encode/decode round-trip (header fields + SACK extension).
- Connection ID derivation (initiator recv=seed/send=seed+1; responder recv=id+1/send=id).
- seq/ack wrap-around (`seqLE`/`seqGT`) for the 16-bit space.
- Full initiator↔responder handshake over a loopback `UDPSocket` pair.

### Live test

Once interop passes: `torrent-cli add <magnet> --peer ...` or the app, and watch for µTP peers connecting (log line like the MSE one). The Odyssey swarm is the real-world target — WebTorrent downloads it partly because it speaks µTP.

## References (all in `third-party/`, gitignored)

- **libutp C++ source** (the reference impl): `third-party/webtorrent/node_modules/utp-native/deps/libutp/`
  - `utp_internal.cpp` (3494 lines) — the protocol engine. Key lines: header struct `:112`, packet types `:148`, conn states `:161`, `write_outgoing_packet` `:994`, extension parsing `:1833`, incoming demux `:2815`, SYN accept `:2992`.
  - `utp_internal.h`, `utp.h`, `utp_api.cpp`, `utp_utils.cpp`.
- **Node binding wrapper** (how to drive it from JS): `third-party/webtorrent/node_modules/utp-native/`
  - `index.js`, `lib/connection.js`, `binding.cc`.
- **webtorrent integration** (how a client uses µTP as a peer transport): `third-party/webtorrent/lib/peer.js`, `lib/utp.cjs`.
- **anacrolix/torrent** (Go): `third-party/anacrolix-torrent/utp.go` + `utp_go.go` — abstracts the utp Socket interface (uses an external package, not vendored).

## Key libutp line references

| Concern | File:line |
|---|---|
| Packet header layout | `utp_internal.cpp:112` |
| Packet types (ST_*) | `utp_internal.cpp:148` |
| Connection states (CS_*) | `utp_internal.cpp:161` |
| Outgoing packet framing | `utp_internal.cpp:994` |
| Extension header parse | `utp_internal.cpp:1833` |
| Incoming UDP demux + RST | `utp_internal.cpp:2815` |
| SYN accept / responder init | `utp_internal.cpp:2992` |
| Initiator connect init | `utp_internal.cpp:2748` |

## Suggested next steps

1. Fix `UTPTransport` receive loop to use a detached `Task` (bug #1) — this unblocks everything.
2. Get the loopback interop test passing against `utp-native` (SYN → STATE → DATA echo).
3. Add the unit tests.
4. Wire µTP into `PeerSession` as an alternative transport alongside TCP (mirror how `Peer` in webtorrent does TCP-then-µTP fallback: `lib/peer.js`).
5. Live-test on the Odyssey swarm; verify µTP peers connect.
6. Update `docs/planning.md` (move µTP out of "deferred") and add an implementation-notes entry before committing.
