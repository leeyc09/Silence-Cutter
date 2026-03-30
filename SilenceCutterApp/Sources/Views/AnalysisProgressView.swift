import SwiftUI

/// Displays analysis progress with distinct UI for model download vs analysis phases.
struct AnalysisProgressView: View {
    let progress: ProgressInfo?

    var body: some View {
        VStack(spacing: 16) {
            if let progress {
                if progress.phase == "model_download" {
                    modelDownloadView(progress)
                } else {
                    analysisView(progress)
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

    // MARK: - Model Download UI

    private func modelDownloadView(_ progress: ProgressInfo) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.cyan)
                .symbolEffect(.pulse, options: .repeating)

            Text("AI 모델 다운로드")
                .font(.title3.bold())

            Text("처음 실행 시에만 필요합니다")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ProgressView(value: Double(progress.percent), total: 100)
                    .progressViewStyle(.linear)
                    .tint(.cyan)
                    .frame(maxWidth: 280)

                if !progress.detail.isEmpty {
                    Text(progress.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(progress.percent)%")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }

    // MARK: - Analysis UI

    private func analysisView(_ progress: ProgressInfo) -> some View {
        VStack(spacing: 12) {
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
        }
    }

    // MARK: - Phase Display Names

    private static func phaseDisplayName(_ phase: String) -> String {
        switch phase {
        case "analyze": "분석"
        case "vad": "음성 감지"
        default: phase
        }
    }
}

#Preview("Model Download") {
    AnalysisProgressView(progress: ProgressInfo(phase: "model_download", percent: 34, detail: "다운로드 중… 327 / 960 MB"))
        .preferredColorScheme(.dark)
}

#Preview("Analysis") {
    AnalysisProgressView(progress: ProgressInfo(phase: "analyze", percent: 66, detail: "전사 중 (35/41)"))
        .preferredColorScheme(.dark)
}

#Preview("No Progress") {
    AnalysisProgressView(progress: nil)
        .preferredColorScheme(.dark)
}
