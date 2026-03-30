import SwiftUI
import AVKit

/// NSViewRepresentable wrapper around AVKit's AVPlayerView.
/// Using NSViewRepresentable directly instead of SwiftUI's VideoPlayer
/// to avoid a runtime demangle crash with AVPlayerView on macOS.
private struct PlayerNSView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVKit.AVPlayerView {
        let view = AVKit.AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVKit.AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// A video player view that wraps AVKit's AVPlayerView and supports drag-and-drop
/// of video files. Shows a placeholder prompt when no video is loaded.
struct VideoPreviewView: View {
    @Bindable var model: VideoPlayerModel

    /// Accepted video file extensions for drag-and-drop.
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "mp3", "wav", "m4a", "aac", "flac", "ogg", "webm"
    ]

    var body: some View {
        ZStack {
            if let player = model.player {
                PlayerNSView(player: player)
            } else {
                placeholderView
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first,
                  Self.isVideoFile(url) else {
                return false
            }
            model.loadVideo(url: url)
            return true
        }
    }

    // MARK: - Subviews

    private var placeholderView: some View {
        ZStack {
            Rectangle()
                .fill(.black)
            Text(L10n.tr("preview.placeholder"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.5))
                .font(.title3)
        }
    }

    // MARK: - Helpers

    /// Check whether the URL points to a video file by extension.
    private static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}
