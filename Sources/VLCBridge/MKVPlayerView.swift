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
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                }

                controls
                    .padding(.bottom)
            }
        }
        .onAppear {
            configureAudioSession()
        }
        .onDisappear {
            session.teardown()
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { session.durationMs > 0 ? Double(session.positionMs) / Double(session.durationMs) : 0 },
                    set: { session.seek(toMs: Int64(Double(session.durationMs) * $0)) }
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
