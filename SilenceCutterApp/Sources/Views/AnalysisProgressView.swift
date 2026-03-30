import SwiftUI

/// Displays analysis progress: phase name, linear progress bar, and detail text.
/// Shows an indeterminate spinner when progress info is nil (analysis starting up).
struct AnalysisProgressView: View {
    let progress: ProgressInfo?

    var body: some View {
        VStack(spacing: 12) {
            if let progress {
                Text(Self.phaseDisplayName(progress.phase))
                    .font(.headline)

                ProgressView(value: Double(progress.percent), total: 100)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)

                Text("\(progress.percent)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !progress.detail.isEmpty {
                    Text(progress.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                Text("분석 준비 중…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Map Python phase names to user-facing Korean labels.
    private static func phaseDisplayName(_ phase: String) -> String {
        switch phase {
        case "model_download": "모델 다운로드"
        case "analyze": "분석"
        case "vad": "음성 감지"
        default: phase
        }
    }
}

#Preview("With Progress") {
    AnalysisProgressView(progress: ProgressInfo(phase: "VAD 처리 중", percent: 42, detail: "Processing audio segments..."))
}

#Preview("No Progress") {
    AnalysisProgressView(progress: nil)
}
