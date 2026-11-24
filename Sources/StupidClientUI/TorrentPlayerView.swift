import AVFoundation
import AVKit
import Streaming
import StupidClientCore
import SwiftUI

public struct TorrentPlayerView: View {
    let request: PlaybackRequest
    let store: TorrentStore

    @State private var session: TorrentStreamSession?
    @State private var player: AVPlayer?

    public init(request: PlaybackRequest, store: TorrentStore) {
        self.request = request
        self.store = store
    }

    public var body: some View {
        Group {
            if let player {
                #if os(macOS)
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                #else
                PlayerController(player: player)
                    .ignoresSafeArea()
                #endif
            } else {
                ProgressView()
            }
        }
        .task {
            let session = TorrentStreamSession(torrent: request.torrent, fileIndex: request.fileIndex)
            self.session = session
            let prepared = await session.makePlayer()
            guard !Task.isCancelled else {
                prepared.pause()
                return
            }
            if let resume = store.resumePosition(
                torrent: request.torrent,
                fileIndex: request.fileIndex,
                duration: prepared.currentItem?.duration.seconds ?? .nan
            ) {
                prepared.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) { _ in }
            }
            player = prepared
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if prepared.timeControlStatus == .playing {
                    recordPlayhead(of: prepared)
                }
            }
        }
        .onDisappear {
            if let player {
                recordPlayhead(of: player)
            }
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            session?.stop()
        }
    }

    private func recordPlayhead(of player: AVPlayer) {
        guard let item = player.currentItem else { return }
        store.recordPlayhead(
            seconds: player.currentTime().seconds,
            duration: item.duration.seconds,
            torrent: request.torrent,
            fileIndex: request.fileIndex
        )
    }
}

#if !os(macOS)
private struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> LoadingIndicatorCoordinator {
        LoadingIndicatorCoordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback)
        try? audioSession.setActive(true)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.color = .white
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        let overlayView = controller.contentOverlayView ?? controller.view!
        overlayView.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
        ])
        context.coordinator.observe(player: player, indicator: indicator)
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

@MainActor
private final class LoadingIndicatorCoordinator {
    private weak var indicator: UIActivityIndicatorView?
    private var observations: [NSKeyValueObservation] = []

    func observe(player: AVPlayer, indicator: UIActivityIndicatorView) {
        self.indicator = indicator
        observations = [
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let playing = player.timeControlStatus == .playing
                Task { @MainActor in
                    if playing { self?.stop() }
                }
            },
            player.observe(\.currentItem?.status, options: [.initial, .new]) { [weak self] player, _ in
                let failed = player.currentItem?.status == .failed
                Task { @MainActor in
                    if failed { self?.stop() }
                }
            },
        ]
    }

    private func stop() {
        indicator?.stopAnimating()
        observations.removeAll()
    }
}
#endif
