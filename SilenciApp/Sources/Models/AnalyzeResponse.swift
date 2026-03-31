import Foundation

/// Top-level response from the Python `analyze` JSON-RPC method.
/// Contains transcribed segments and video metadata.
struct AnalyzeResponse: Codable, Sendable {
    let segments: [Segment]
    let videoInfo: VideoInfo
    /// Total timeline duration (for resub, may differ from video duration).
    /// nil when from a fresh analysis.
    let timelineDuration: Double?

    enum CodingKeys: String, CodingKey {
        case segments
        case videoInfo = "video_info"
        case timelineDuration = "timeline_duration"
    }
}

/// Video file metadata returned alongside analysis results.
struct VideoInfo: Codable, Sendable {
    let fps: Double
    let width: Int
    let height: Int
    let duration: Double
}

/// Response from the Python `retranscribe_to_file` JSON-RPC method.
struct RetranscribeResponse: Codable, Sendable {
    let outputPath: String
    let ittPath: String?

    enum CodingKeys: String, CodingKey {
        case outputPath = "output_path"
        case ittPath = "itt_path"
    }
}
