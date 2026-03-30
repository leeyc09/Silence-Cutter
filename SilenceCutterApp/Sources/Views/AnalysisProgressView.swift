import SwiftUI

/// Displays analysis progress with distinct UI for model download vs analysis phases.
/// Includes a cancel button.
struct AnalysisProgressView: View {
    let progress: ProgressInfo?
    var onCancel: (() -> Void)? = nil

    /// Track the last analysis percent so model_download doesn't reset it.
    @State private var lastAnalyzePercent: Int = 0

    var body: some View {
        VStack(spacing: 16) {
            if let progress {
                if progress.phase == "model_download" {
                    combinedView(progress)
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

            // Cancel button
            if let onCancel {
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Label("취소", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: progress?.phase) { _, newPhase in
            if newPhase == "model_download", let p = progress, p.phase != "model_download" {
                lastAnalyzePercent = p.percent
            }
        }
        .onChange(of: progress?.percent) { _, newPercent in
            if let p = progress, p.phase != "model_download" {
                lastAnalyzePercent = newPercent ?? 0
            }
        }
    }

    // MARK: - Combined: Analysis progress + Model download sub-progress

    private func combinedView(_ dlProgress: ProgressInfo) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("분석")
                    .font(.headline)
                ProgressView(value: Double(lastAnalyzePercent), total: 100)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text("\(lastAnalyzePercent)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.cyan)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("AI 모델 다운로드")
                        .font(.subheadline.bold())
                        .foregroundStyle(.cyan)
                }
                ProgressView(value: Double(dlProgress.percent), total: 100)
                    .progressViewStyle(.linear)
                    .tint(.cyan)
                    .frame(maxWidth: 240)
                if !dlProgress.detail.isEmpty {
                    Text(dlProgress.detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cyan.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
                    )
            )
        }
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

    private static func phaseDisplayName(_ phase: String) -> String {
        switch phase {
        case "analyze": "분석"
        case "vad": "음성 감지"
        default: phase
        }
    }
}
