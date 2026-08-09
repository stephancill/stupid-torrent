# Scope — Matroska → fMP4 transmuxer (AVPlayer-native MKV playback)

Status: **implemented (2026-08-09).** Gates 0-4 landed: EBML/Matroska parsing, init segment + fragments, streaming through `TorrentStreamSession`'s resource loader, and live/partial playback (streamed a 30 s MKV at 5/11 pieces). VLCKit is removed (app back to ~3 MB). Remaining: precise far seeks (sidx), and full device validation. This doc is now the design record for the shipped approach.

## TL;DR

AVFoundation cannot demux Matroska, so the only way to get `.mkv` into the native AVPlayer is to **transmux on the fly**: parse the MKV in Swift and feed AVPlayer a byte-range–seekable fragmented MP4 (fMP4) through the existing `AVAssetResourceLoaderDelegate` (`TorrentStreamSession`). This is a large correctness effort with a real failure risk (AVPlayer is finicky about fMP4 box accuracy). Critically, **AVPlayer does decode E-AC-3/AC-3 (incl. Atmos) in ISO-BMFF** — verified empirically 2026-08-09 on macOS 26.3 and the iOS 26.3 simulator (`AVAssetReader` pulls `ec-3`/`ac-3` samples; the same tracks in an MKV are refused with `Cannot Open`, confirming the container was the only blocker). So the Backrooms file's audio survives the transmux; what's actually lost is embedded subtitles and Opus/Vorbis/FLAC/DTS audio. It buys back: no ~225 MB framework, no LGPL obligations, native PiP/AVPlayerViewController controls.

## Why AVPlayer can't just open the MKV

AVFoundation ships a fixed demuxer set (mp4/mov/m4a/mp3/aac/wav + a few others). Matroska is not among them, regardless of the codec inside. The container itself is rejected, so `AVURLAsset` on a `.mkv` reports unplayable. The transmuxer exists to change what AVPlayer sees: a well-formed fMP4 whose bytes are *derived* from the MKV.

## Goal

- Play `.mkv`/`.mka` with **AVPlayer** (`AVPlayerViewController`, native controls + PiP) while the torrent is still downloading, from verified bytes only.
- Reuse everything already built: `TorrentStreamSession`/`TorrentResourceLoaderDelegate`, `Torrent.streamPriority` (jump vs window), `streamingAvailability`/`streamingRead`, the moov-tail analog (the MKV `Tracks` head + first clusters + Cues tail).
- Keep `TorrentCore`/`Streaming`/`torrent-cli`/`swift test` dependency-free and macOS-buildable.
- Drop VLCKit entirely (and `VLCBridge`), or keep both behind a flag during a transition.

## Non-goals (v1)

- **Embedded subtitles** (SRT/ASS/PGS). AVPlayer fMP4 text-track support is limited; v1 drops MKV subtitle tracks. (SRT→WebVTT extraction is a possible follow-up, not v1.)
- Opus/Vorbis/FLAC/DTS audio in MKV (AVPlayer won't decode them in fMP4).
- WebM/AVI (separate containers, same problem).
- Audio/video **transcoding** (would need an encoder build; explicitly rejected).

> **Changed 2026-08-09**: E-AC-3/AC-3/Atmos was previously a hard non-goal ("video-only on Backrooms"). Empirically it is **not** — AVFoundation decodes `ec-3`/`ac-3` in ISO-BMFF on macOS 26.3 and iOS 26.3 sim. The transmuxer only needs to emit the correct `ec-3`/`ac-3` sample entries (see "Codec extradata"), not transcode.

## Codec matrix (what actually plays)

| MKV track | AVPlayer in fMP4 | Notes |
|---|---|---|
| H.264 (`avc1`/`avc3`) | ✅ | `avcC` = CodecPrivate verbatim (verified: ffmpeg writes the record) |
| HEVC/H.265 (`hvc1`/`hev1`, Main/Main10) | ✅ | `hvcC` = CodecPrivate verbatim (verified); Main10 fine on device, software-decode on sim |
| AAC (`A_AAC`) | ✅ | `AudioSpecificConfig` = CodecPrivate verbatim (verified) |
| E-AC-3 / AC-3 (`A_EAC3`/`A_AC3`, incl. Atmos) | ✅ | **Verified 2026-08-09**: `AVAssetReader` decodes `ec-3`/`ac-3` in MP4 on macOS 26.3 + iOS 26.3 sim. Backrooms audio survives. Needs `ec-3`/`ac-3` sample entries with `dec3`/`dac3` boxes built from syncframe headers (the mux work, see "Codec extradata") |
| MP3 (`A_MPEGL3`) | ⚠️ | AVPlayer supports MP3 in some containers; treat as out-of-scope unless trivial |
| ALAC | ✅ | Rare in MKV |
| Opus/Vorbis/FLAC/DTS | ❌ | Out of scope |
| SRT/ASS/PGS subs | ❌ | Dropped in v1 |

**This matrix is the crux of the decision.** VLCKit plays everything (incl. embedded subs + Opus/Vorbis/FLAC/DTS); a v1 transmuxer plays H.264/HEVC video and AAC/E-AC-3/AC-3/ALAC audio — i.e. everything *except* embedded subtitles and the rare audio codecs. The 2026-08-09 verification removed the previous "video-only on Backrooms" blocker.

## Architecture

```
                 +---------------------------------------------------------+
                 |  TransmuxingSource (new, in Streaming or new target)     |
 AVPlayer path   |    MatroskaReader  ──►  fMP4Writer                       |
                 |        │                      │                          |
                 |  TorrentStreamSource (verified bytes of the .mkv)        |
                 +---------------------------------------------------------+
                                 ▲
                                 │ reads/prioritizes the real MKV
                 +---------------------------------------------------------+
                 |  TorrentStreamSession (AVAssetResourceLoaderDelegate)     |
                 |  serves the *virtual fMP4* to AVPlayer                    |
                 +---------------------------------------------------------+
```

The loader today serves a file's raw bytes. For MKV it instead serves a **virtual fMP4**: AVPlayer issues `contentInformationRequest` + byte-range data requests against the fMP4's coordinates; the loader asks the transmuxer to produce the fMP4 bytes for that range from the MKV's verified bytes.

### Component 1 — `EBMLParser` (new, Foundation-only)

- Generic EBML element reader over a `TorrentStreamSource` (byte-at-a-time / bounded reads): variable-length integers, element IDs (1–4 byte), sizes (unknown-size elements incl. the Segment), nesting.
- Must handle: unknown-size Segment, unknown-size Cluster, lacing (Xiph/EBML/fixed) in SimpleBlocks, `BlockGroup`/`Block`, `ReferenceBlock`, discard padding, `BlockAdditional`.
- Strict but lenient enough for real-world files (malformed → loud failure, not a hang).
- **Hermetic**: golden-byte unit tests (hand-built EBML streams + real ffmpeg MKV fixtures).

### Component 2 — `MatroskaReader`

- Parses: EBML header (doc type, version), Segment Info (`Duration`, `TimecodeScale`, `TimestampScale`), `Tracks` → per-track `CodecID`, `CodecPrivate`, `DefaultDuration`, pixel/audio params, track type, default flag, language; `Cues` (seek index, for accurate seeks); `Cluster` → `SimpleBlock`s.
- Produces the "movie facts" the fMP4 needs: timescale, duration, per-track sample descriptions + codec config (avcC/hvcC/ASC), keyframe flags, and a cluster → time index.
- **Reads are driven by the verified-byte source** — the reader must be incremental: it parses the head (Segment/Tracks, small) then streams clusters as they verify, exactly like the current loader polls `streamingAvailability`.

### Component 3 — `fMP4Writer`

- Boxes: `ftyp` (`isom`/`iso6`/`dash`), `moov` (`mvhd`, `trak`→`mdia`→`minf`→`stbl`, one `trak` per kept track: `stsd` with `avc1`/`hvc1`/`mp4a` sample descriptions built from the extradata, `stts`, `stsc`, `stsz`, `stco`/`co64`), then a sequence of fragments: `moof` (`mfhd`, `traf`→`tfhd`/`tfdt`/`trun`) + `mdat`.
- **Timestamps**: convert MKV cluster/timecode + `DefaultDuration` into fMP4 `tfdt`/`trun` CTS/DTS with a single timescale; apply sample flags (keyframe/delta) and edit lists so first-sample PTS starts at 0.
- Deterministic output is *not* required if the loader serves ranges on demand; see Risks.

### Component 4 — byte-range serving (the hard 20%)

AVPlayer's resource loader supports:
1. `isByteRangeAccessSupported = false` + sequential to end → simplest, but **disables seeking** and may require the whole thing.
2. `isByteRangeAccessSupported = true` + real byte ranges → seeking works, but AVPlayer requests exact offsets into the virtual fMP4; **every byte must be exactly right**.

The v1 target is (2). Design:
- Build the **init segment** (`ftyp`+`moov`) up front from the parsed head. Its size is fixed and known → AVPlayer's early range requests hit it directly.
- Fragments are generated per time-window. AVPlayer asks for a byte range; the transmuxer maps the offset → fragment index → MKV cluster offset → `streamingRead`. If the MKV bytes for that fragment aren't verified yet, **block until they are** (the same "seek/read waits, doesn't fail" contract the HTTP server uses), then generate and serve the fragment.
- **Content length**: the virtual fMP4's length isn't known until every fragment is sized. Options, in order of preference:
  a. Make fragment sizes deterministic (fixed sample table / constant fragment duration) so the total length is computable up front. Constrains the muxer (e.g., no variable-size lacing surprises) but gives AVPlayer a real `Content-Length` and byte-range seekability — the moov-tail analog.
  b. Report a provisional large length and serve ranges on demand; AVPlayer tolerates out-of-range responses (416-style) but this risks mid-stream failures.
  - (a) is strongly preferred; it also makes seeking (below) tractable.

### Seeking

- AVPlayer seeks by requesting the byte range covering the fragment whose `tfdt` contains the target time. With deterministic fragment sizes + a generated `stbl`/fragment index, the transmuxer maps time → fragment → MKV cluster via the MKV `Cues`. 
- **Cues-less MKVs** (common): no accurate time→cluster map. Fallbacks: linear scan from the last known cluster (slow on a 4.78 GB file), or build a running index as clusters stream by. v1: running index + documented imprecision; a seek into a not-yet-streamed region falls back to "wait for sequential arrival" — the same UX as VLCKit today on a partial file.
- Tail-Cues priority: mirror the current moov-tail jump (`streamPriority` jump-level 10 on the last ~2 MB) so the MKV Cues are downloaded early and seeks are accurate.

### Codec extradata extraction (cheaper than the doc originally assumed)

Verified 2026-08-09 against ffmpeg-generated fixtures (dumped raw `Tracks` `CodecPrivate`): for spec-compliant muxers the MKV `CodecPrivate` **is already the ISO decoder-config record** — the extraction is mostly copy-paste into the `stsd` sample entry, not NAL assembly.

- **H.264**: `V_MPEG4/ISO/AVC` CodecPrivate is the complete `avcC` (`01 64 00 0c ff e1 001a <SPS> 01 0006 <PPS>` = configurationVersion/profile/compat/level/lengthSizeMinusOne/SPS/PPS). Copy verbatim into the `avc1` sample entry.
- **HEVC**: `V_MPEGH/ISO/HEVC` CodecPrivate is the complete `hvcC` (`01 02 20 00 00 00 90 …` = config record). Copy verbatim into the `hvc1`/`hev1` sample entry. **Backrooms is HEVC Main 10** — with the record pre-assembled this is low-risk, but Gate 1 still validates it against `ffprobe`.
- **AAC**: `A_AAC` CodecPrivate is already `AudioSpecificConfig` (`12 08 56 e5 00` = 2 bytes ASC). Wrap in `esds`/`mp4a`.
- **E-AC-3 / AC-3 (the actual new work)**: `A_EAC3`/`A_AC3` CodecPrivate is a raw **syncframe**, not a config record. The muxer must parse the syncframe header (`bsid`, `fscod`, `acmod`, `lfeon`, …) to build the `dec3`/`dac3` box and to frame each sample as exactly one syncframe. Well-documented, verifiable against `ffprobe`; adds ~1-2 pts vs the original plan.
- Lenient fallback: non-compliant muxers that store Annex-B NALs for AVC/HEVC (recognized by the leading `00 00 00 01` start code) → assemble the record; log loudly otherwise.
- Follow `docs/mkv-streaming.md`'s Cues-tail precedent: prioritize the `Tracks` region at session start so extradata is available immediately.

## Files & targets (rough)

| File | Change |
|---|---|
| `Sources/Streaming/EBMLParser.swift` | New — generic EBML reader |
| `Sources/Streaming/MatroskaReader.swift` | New — MKV structure → track/sample facts |
| `Sources/Streaming/fMP4Writer.swift` | New — init segment + fragment boxes |
| `Sources/Streaming/TransmuxSource.swift` | New — `TorrentStreamSource` adapter + virtual-file range mapper |
| `Sources/Streaming/TorrentStreamSession.swift` | Branch: mkv → serve virtual fMP4 via `TransmuxSource` |
| `Sources/TorrentCore/Torrent+Streaming.swift` | `PlaybackKind` mkv → `.avPlayer` (or new `.transmux`), or keep `.vlc` until migration done |
| `Sources/stupid_torrent_client/Views.swift` | mkv rows open `PlayerView` (AVPlayer) instead of `MKVPlayerView` |
| `Tests/EBMLParserTests.swift`, `Tests/MatroskaReaderTests.swift`, `Tests/fMP4WriterTests.swift`, `Tests/TransmuxTests.swift` | Hermetic fixtures |
| Delete (after migration) | `VLCBridge`, `MKVPlayerView`, `MKVStreamSession`, `TorrentHTTPServer` usage, `Vendor/MobileVLCKit.xcframework` refs, `docs/mkv-streaming.md` → supersede |

`Streaming` stays Foundation/AVFoundation-only (it already imports AVFoundation), so `swift build`/`swift test`/`torrent-cli` stay green with no VLC.

## Phases & gates (abort-friendly)

Gate 0 — **EBML parser + fixtures**. Golden-byte + real ffmpeg MKV fixtures. Gate: all unit tests pass; a raw dump of a fixture's Tracks/Cues matches `mkvinfo`/`ffprobe`.

Gate 1 — **Header → init segment**. Parse Segment Info/Tracks, extract avcC/hvcC/ASC, emit `ftyp`+`moov` for an H.264 and a HEVC fixture. Gate: `ffprobe` and headless `AVAsset.isPlayable` accept the generated init segment, and AVPlayer reports the correct duration.

Gate 2 — **Clusters → fragments, sequential playback**. Mux streamed clusters into `moof`/`mdat`, feed via the loader. Gate: AVPlayer plays a small H.264+AAC MKV end-to-end from the transmuxed stream (hermetic, then sim).

Gate 3 — **Byte-range + seeking**. Deterministic fragments, Cues-driven time→byte map, tail-Cues priority. Gate: `stream-play --seek-to`-style seeks land accurately; a Cues-less fixture falls back gracefully.

Gate 4 — **Live/partial torrent**. Verified-byte reads block on unverified regions, priority windows drive the download, playback starts before 100%. Gate: partial-download playback (mirror the current `stream-test` methodology).

Gate 5 — **Codec matrix + app routing**. HEVC Main 10 + E-AC-3 Atmos (Backrooms), AAC, AC-3, H.264 validated; mkv rows route to AVPlayer; PiP works; VLCBridge removed. Gate: full app flow on device; `swift test` green; `git diff --check` clean.

**Abort criterion**: if at any gate AVPlayer rejects a valid fMP4 for a fixture (box/timestamp/extradata intolerance we can't fix in one session), stop and re-evaluate — the same risk profile as VLCKit's packaging gate. The doc'd fallback after that would be to keep VLCKit.

## Key risks

| Risk | Mitigation |
|---|---|
| fMP4 box/timestamp intolerance (AVPlayer rejects subtly-wrong bytes) | Gate 1-2 validate every layer against ffprobe + headless AVAsset before any UI; small fixtures first |
| **E-AC-3/AC-3 `dec3`/`dac3` assembly wrong** → Backrooms audio fails | Gate 1 golden test: mux an `ec-3`/`ac-3` track and assert AVAssetReader decodes it (decode itself already verified on macOS + iOS 26.3 sim); `ffprobe` on the Backrooms-track-equivalent fixture |
| Virtual-file Content-Length unknown until end | Deterministic fragment sizing (fragment duration + fixed tables) so total length is computable; reject variable-lace edge cases that break determinism |
| Cues-less MKV seeks | Running cluster index built as clusters stream; documented imprecision; fallback to sequential wait |
| Byte-range requests for not-yet-verified MKV data | Block (poll availability) like the HTTP server; jump-priority the requested window |
| HEVC `hvcC` (CodecPrivate) misread → motivating file fails | Gate 1 golden test against `ffprobe` on the Backrooms-track-equivalent fixture (HEVC Main 10); with the record copied verbatim this is low-risk |
| Effort overruns / sunk cost | Gates 0-2 (16 of 34 pts) are the cheap feasibility proof: validate AVPlayer accepts the fMP4 before investing in seeking/live/perf |
| Subtitles lost | Explicit v1 non-goal; SRT→WebVTT extraction as a follow-up if VLCKit is dropped |

## Effort (points)

- Gate 0 (EBML): 3
- Gate 1 (init segment + extradata): 4 (was 5 — CodecPrivate for AVC/HEVC/AAC is the config record verbatim, verified; E-AC-3 `dec3`/`dac3` work moved to Gate 2)
- Gate 2 (fragments + sequential playback, incl. E-AC-3/AC-3 syncframe framing + `dec3`/`dac3`): 9 (was 8)
- Gate 3 (byte-range + seeking): 8
- Gate 4 (live/partial): 5
- Gate 5 (codec matrix + routing + removal): 5
- **Total: 34**, with risk concentrated in Gates 1–3 (fMP4 correctness).

## Decision

- **VLCKit (current)**: plays the Backrooms file fully today (HEVC + E-AC-3 + SRT), already integrated; costs app size + LGPL and the recent player polish (spinner/seek/blank-screen fixes just landed).
- **Transmuxer**: native AVPlayer controls + PiP, no framework/LGPL, ~34 pts, a real fMP4-rejection risk, and — per the 2026-08-09 verification — **full A/V on Backrooms** (HEVC + E-AC-3 Atmos both decode in fMP4); the residual gaps vs VLCKit are **embedded subtitles and Opus/Vorbis/FLAC/DTS audio**.

Recommendation: **keep VLCKit as primary** unless its app-size/LGPL cost or a hard technical blocker forces a move. The 2026-08-09 verification removed the "video-only on Backrooms" blocker, so if the move happens the transmuxer now preserves the motivating file's audio; the real remaining decision is whether losing embedded subtitles + Opus/Vorbis/FLAC/DTS audio is acceptable. Gates 0–2 (the cheap proof) should precede committing to the full effort.

## Verification log

- **2026-08-09 — E-AC-3/AC-3 decode in AVPlayer (container was the only blocker)**: generated H.264 + E-AC-3 5.1 and H.264 + AC-3 fixtures, muxed both to MP4 and MKV. On macOS 26.3 host and the iOS 26.3 simulator (`6552DF1D`): the MP4s report `isPlayable = true`, expose `ec-3`/`ac-3` audio tracks, and an `AVAssetReader` pulls 5 decoded samples; the identical tracks in MKV fail with AVFoundation `Cannot Open` (`-11828`, unsupported format). Conclusion: AVFoundation demuxes and decodes Dolby Digital (Plus) in ISO-BMFF; only the Matroska container is refused.
- **2026-08-09 — CodecPrivate is the config record (fixtures dumped)**: ffmpeg MKVs store the complete `avcC` (AVC), `hvcC` (HEVC Main 10), and `AudioSpecificConfig` (AAC) in `Tracks` `CodecPrivate` verbatim — no NAL re-assembly needed for spec-compliant files.

## References

- `docs/mkv-streaming.md` — the VLCKit plan this would replace; Decisions §1 (transmux rejection rationale), Architecture, Verification.
- `Sources/Streaming/TorrentStreamSession.swift` — the loader to extend (resource-loader delegate, byte-range serving, all-to-end/bounded/probe request shapes).
- `Sources/Streaming/StreamDataSource.swift` — `TorrentStreamSource` abstraction the reader/writer consume.
- `Sources/TorrentCore/Torrent+Streaming.swift` — `streamPriority` jump/window, `streamingAvailability`/`streamingRead`, `PlaybackKind`.
- `Sources/Streaming/TorrentHTTPServer.swift` — the blocking/progressive-serve pattern to mirror for unverified ranges.
- Specs: EBML 1.4, Matroska 4, ISO/IEC 14496-12 (fMP4), 14496-15 (avcC/hvcC).
