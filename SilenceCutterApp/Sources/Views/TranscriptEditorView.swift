import SwiftUI

/// Interactive transcript editor replacing the read-only SegmentListView.
/// Shows each segment as a row with a checkbox (keep/discard), time range, and tappable text that seeks.
struct TranscriptEditorView: View {
    @Bindable var analysisService: AnalysisService
    var onSeek: (TimeInterval) -> Void

    var body: some View {
        if analysisService.segments.isEmpty {
            ContentUnavailableView(
                "분석 결과가 없습니다",
                systemImage: "text.magnifyingglass",
                description: Text("음성이 감지되지 않았습니다.")
            )
        } else {
            List(Array(analysisService.segments.enumerated()), id: \.element.id) { index, segment in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: $analysisService.segments[index].isKept)
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(formatTime(segment.start)) – \(formatTime(segment.end))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        Button {
                            onSeek(segment.start)
                        } label: {
                            Text(segment.text)
                                .font(.body)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .strikethrough(!segment.isKept)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                .opacity(segment.isKept ? 1.0 : 0.5)
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Time formatting

/// Format seconds as MM:SS.s (e.g. 01:23.4)
private func formatTime(_ seconds: Double) -> String {
    let totalSeconds = max(0, seconds)
    let minutes = Int(totalSeconds) / 60
    let secs = totalSeconds.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%04.1f", minutes, secs)
}

#Preview("With Segments") {
    @Previewable @State var service = AnalysisService()
    TranscriptEditorView(analysisService: service, onSeek: { _ in })
        .frame(width: 300, height: 300)
        .onAppear {
            service.segments = [
                Segment(start: 0.5, end: 3.2, text: "안녕하세요, 오늘은 날씨가 좋습니다."),
                Segment(start: 5.0, end: 8.1, text: "테스트 세그먼트입니다.", isKept: false),
                Segment(start: 62.3, end: 65.7, text: "1분이 넘는 타임스탬프 예시"),
            ]
        }
}

#Preview("Empty") {
    @Previewable @State var service = AnalysisService()
    TranscriptEditorView(analysisService: service, onSeek: { _ in })
        .frame(width: 300, height: 300)
}
