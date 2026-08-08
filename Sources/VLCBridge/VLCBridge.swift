import Foundation

/// iOS-only bridge between the torrent engine's verified-byte stream APIs and
/// VLCKit (MobileVLCKit) for MKV/MKA playback. The file bodies are guarded so the
/// target compiles to an empty module on macOS (the host `swift build`/`swift test`
/// path never links MobileVLCKit).
///
/// See docs/mkv-streaming.md for the full design.
