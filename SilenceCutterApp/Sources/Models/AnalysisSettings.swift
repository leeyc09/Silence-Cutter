import Foundation

/// User-configurable settings for analysis and export.
///
/// Stored in UserDefaults and observed by SwiftUI views.
@MainActor
@Observable
final class AnalysisSettings {

    // MARK: - Language

    /// Speech language for ASR.
    var language: String = "Korean"

    /// Available language options.
    static let languages = ["Korean", "English", "Japanese", "Chinese"]

    // MARK: - ASR Model

    /// ASR model identifier.
    var asrModel: ASRModel = .small

    enum ASRModel: String, CaseIterable, Identifiable, Sendable {
        case small = "mlx-community/Qwen3-ASR-0.6B-8bit"
        case large = "mlx-community/Qwen3-ASR-1.7B-8bit"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .small: "Qwen3-ASR 0.6B (빠름)"
            case .large: "Qwen3-ASR 1.7B (고품질)"
            }
        }
    }

    // MARK: - VAD Settings

    /// VAD sensitivity threshold (0~1). Lower = more sensitive.
    var vadThreshold: Double = 0.5

    /// Minimum speech segment duration in milliseconds.
    var minSpeechMs: Int = 250

    /// Minimum silence duration to detect as a gap (ms).
    var minSilenceMs: Int = 200

    /// Padding added before/after speech segments (ms).
    var speechPadMs: Int = 100

    // MARK: - Segment Settings

    /// Maximum segment duration for display (seconds).
    var maxSegmentSeconds: Double = 8.0

    // MARK: - Subtitle Settings

    /// Maximum characters per subtitle line.
    var maxSubtitleChars: Int = 20

    /// Subtitle font size for FCPXML export.
    var fontSizeExport: Int = 42

    // MARK: - Persistence

    private static let defaults = UserDefaults.standard

    func save() {
        let d = Self.defaults
        d.set(language, forKey: "sc_language")
        d.set(asrModel.rawValue, forKey: "sc_asrModel")
        d.set(vadThreshold, forKey: "sc_vadThreshold")
        d.set(minSpeechMs, forKey: "sc_minSpeechMs")
        d.set(minSilenceMs, forKey: "sc_minSilenceMs")
        d.set(speechPadMs, forKey: "sc_speechPadMs")
        d.set(maxSegmentSeconds, forKey: "sc_maxSegmentSeconds")
        d.set(maxSubtitleChars, forKey: "sc_maxSubtitleChars")
        d.set(fontSizeExport, forKey: "sc_fontSizeExport")
    }

    func load() {
        let d = Self.defaults
        if let v = d.string(forKey: "sc_language") { language = v }
        if let v = d.string(forKey: "sc_asrModel"), let m = ASRModel(rawValue: v) { asrModel = m }
        if d.object(forKey: "sc_vadThreshold") != nil { vadThreshold = d.double(forKey: "sc_vadThreshold") }
        if d.object(forKey: "sc_minSpeechMs") != nil { minSpeechMs = d.integer(forKey: "sc_minSpeechMs") }
        if d.object(forKey: "sc_minSilenceMs") != nil { minSilenceMs = d.integer(forKey: "sc_minSilenceMs") }
        if d.object(forKey: "sc_speechPadMs") != nil { speechPadMs = d.integer(forKey: "sc_speechPadMs") }
        if d.object(forKey: "sc_maxSegmentSeconds") != nil { maxSegmentSeconds = d.double(forKey: "sc_maxSegmentSeconds") }
        if d.object(forKey: "sc_maxSubtitleChars") != nil { maxSubtitleChars = d.integer(forKey: "sc_maxSubtitleChars") }
        if d.object(forKey: "sc_fontSizeExport") != nil { fontSizeExport = d.integer(forKey: "sc_fontSizeExport") }
    }

    /// Reset all settings to defaults.
    func resetToDefaults() {
        language = "Korean"
        asrModel = .small
        vadThreshold = 0.5
        minSpeechMs = 250
        minSilenceMs = 200
        speechPadMs = 100
        maxSegmentSeconds = 8.0
        maxSubtitleChars = 20
        fontSizeExport = 42
        save()
    }
}
