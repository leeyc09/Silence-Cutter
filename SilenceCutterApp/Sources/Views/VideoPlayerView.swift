import SwiftUI
import AVKit

/// A video player view that wraps AVKit's VideoPlayer and supports drag-and-drop
/// of video files. Shows a placeholder prompt when no video is loaded.
struct VideoPlayerView: View {
    @Bindable var model: VideoPlayerModel

    /// Accepted video file extensions for drag-and-drop.
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv"
    ]

    var body: some View {
        ZStack {
            if let player = model.player {
                VideoPlayer(player: player)
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
            Text("영상 파일을 드래그하거나\n파일 열기 버튼을 사용하세요")
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
