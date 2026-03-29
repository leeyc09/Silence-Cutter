import SwiftUI

/// Displays a list of transcribed segments with time ranges and text.
/// Each row shows a monospaced time range (MM:SS.s – MM:SS.s) and the segment text below.
struct SegmentListView: View {
    let segments: [Segment]

    var body: some View {
        if segments.isEmpty {
            ContentUnavailableView(
                "분석 결과가 없습니다",
                systemImage: "text.magnifyingglass",
                description: Text("음성이 감지되지 않았습니다.")
            )
        } else {
            List(segments) { segment in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(formatTime(segment.start)) – \(formatTime(segment.end))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(segment.text)
                        .font(.body)
                        .lineLimit(3)
                }
                .padding(.vertical, 2)
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
    SegmentListView(segments: [
        Segment(start: 0.5, end: 3.2, text: "안녕하세요, 오늘은 날씨가 좋습니다."),
        Segment(start: 5.0, end: 8.1, text: "테스트 세그먼트입니다."),
        Segment(start: 62.3, end: 65.7, text: "1분이 넘는 타임스탬프 예시"),
    ])
    .frame(width: 300, height: 300)
}

#Preview("Empty") {
    SegmentListView(segments: [])
        .frame(width: 300, height: 300)
}
