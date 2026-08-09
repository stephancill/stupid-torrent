import Foundation

#if os(iOS)
import UIKit
import SwiftUI
import AVFoundation
import TorrentCore

/// Minimal SwiftUI player for MKV files, backed by `MKVStreamSession` (VLCKit). Renders VLC's
/// output into a plain `UIView` drawable and overlays basic transport controls.
@MainActor
public struct MKVPlayerView: View {
    @StateObject private var session: MKVStreamSession
    @Environment(\.dismiss) private var dismiss
    /// The slider position while the user is scrubbing, so the thumb follows the finger without
    /// issuing VLC seeks on every tick. A debounce issues a single seek shortly after the drag
    /// stops.
    @State private var scrubTarget: Double?
    @State private var seekTask: Task<Void, Never>?

    public init(torrent: Torrent, fileIndex: Int) {
        _session = StateObject(wrappedValue: MKVStreamSession(torrent: torrent, fileIndex: fileIndex))
    }

    public init(session: MKVStreamSession) {
        _session = StateObject(wrappedValue: session)
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoDrawableView(session: session)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    Text("MKV")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding()

                Spacer()

                if session.state == .failed {
                    Text("Playback failed")
                        .foregroundStyle(.white)
                } else if session.state == .opening || session.state == .buffering {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.large)
                        if session.state == .buffering, session.downloadProgress < 1, session.downloadProgress > 0 {
                            Text("Buffering — \(Int(session.downloadProgress * 100))% downloaded")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }

                controls
                    .padding(.bottom)
            }
        }
        .onAppear {
            configureAudioSession()
        }
        .onDisappear {
            seekTask?.cancel()
            session.teardown()
        }
    }

    /// Issues a single seek after the last scrub movement, coalescing the many slider ticks a drag
    /// produces into one VLC seek (each seek is a fresh HTTP range request on the torrent file).
    private func scheduleSeek() {
        seekTask?.cancel()
        seekTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let target = scrubTarget, session.durationMs > 0 else { return }
            await MainActor.run {
                session.seek(toMs: Int64(Double(session.durationMs) * target))
                scrubTarget = nil
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: {
                        if let scrubTarget { return scrubTarget }
                        return session.durationMs > 0 ? Double(session.positionMs) / Double(session.durationMs) : 0
                    },
                    set: {
                        scrubTarget = $0
                        scheduleSeek()
                    }
                ),
                in: 0...1
            )
            .tint(.white)
            .disabled(!session.isSeekable || session.durationMs == 0)

            HStack {
                Text(timeString(session.positionMs))
                Spacer()
                Button {
                    session.togglePlayPause()
                } label: {
                    Image(systemName: session.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(timeString(session.durationMs))
            }
            .font(.caption)
            .foregroundStyle(.white)

            if !session.subtitleTracks.isEmpty {
                Picker("Subtitles", selection: Binding(
                    get: { session.subtitleTracks.first(where: { $0.isSelected })?.id ?? -1 },
                    set: { session.selectSubtitleTrack($0) }
                )) {
                    Text("Off").tag(-1)
                    ForEach(session.subtitleTracks) { track in
                        Text(track.name).tag(track.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white)
            }

            if session.audioTracks.count > 1 {
                Picker("Audio", selection: Binding(
                    get: { session.audioTracks.first(where: { $0.isSelected })?.id ?? -1 },
                    set: { session.selectAudioTrack($0) }
                )) {
                    ForEach(session.audioTracks) { track in
                        Text(track.name).tag(track.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white)
            }
        }
        .padding(.horizontal)
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback)
        try? audioSession.setActive(true)
    }

    private func timeString(_ ms: Int64) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Wraps VLC's drawable `UIView` so the session attaches once when the view appears.
private struct VideoDrawableView: UIViewRepresentable {
    let session: MKVStreamSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        session.attach(drawable: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
