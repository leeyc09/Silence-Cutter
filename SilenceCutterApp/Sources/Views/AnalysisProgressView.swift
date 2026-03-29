import SwiftUI

/// Displays analysis progress: phase name, linear progress bar, and detail text.
/// Shows an indeterminate spinner when progress info is nil (analysis starting up).
struct AnalysisProgressView: View {
    let progress: ProgressInfo?

    var body: some View {
        VStack(spacing: 12) {
            if let progress {
                Text(progress.phase)
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
}

#Preview("With Progress") {
    AnalysisProgressView(progress: ProgressInfo(phase: "VAD 처리 중", percent: 42, detail: "Processing audio segments..."))
}

#Preview("No Progress") {
    AnalysisProgressView(progress: nil)
}
