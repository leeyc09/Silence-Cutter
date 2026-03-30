import SwiftUI

/// Vrew-style transcript editor with card-based clip layout.
/// Shows each segment as a ClipCardView. Discarded clips collapse.
/// Supports current-clip highlighting via currentTime.
struct TranscriptEditorView: View {
    @Bindable var analysisService: AnalysisService
    var onSeek: (TimeInterval) -> Void
    var currentTime: TimeInterval = 0

    /// Last auto-scrolled clip index — prevents redundant scrollTo calls.
    @State private var lastScrolledIndex: Int?

    /// Computed index of the currently playing clip
    private var activeClipIndex: Int? {
        analysisService.segments.firstIndex { seg in
            seg.isKept && currentTime >= seg.start && currentTime < seg.end
        }
    }

    var body: some View {
        if analysisService.segments.isEmpty {
            ContentUnavailableView(
                L10n.tr("transcript.no_results"),
                systemImage: "text.magnifyingglass",
                description: Text(L10n.tr("transcript.no_speech"))
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(analysisService.segments.enumerated()), id: \.element.id) { index, segment in
                            ClipCardView(
                                index: index,
                                segment: $analysisService.segments[index],
                                onSeek: onSeek,
                                onSplit: {
                                    analysisService.splitSegment(at: index)
                                },
                                onSplitAtWord: { wordIndex in
                                    analysisService.splitSegment(at: index, wordIndex: wordIndex)
                                },
                                onMerge: index < analysisService.segments.count - 1 ? {
                                    analysisService.mergeWithNext(at: index)
                                } : nil,
                                isActive: activeClipIndex == index
                            )
                            .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .onChange(of: activeClipIndex) { _, newIndex in
                    // Only scroll when clip actually changes — not on every currentTime tick
                    guard let idx = newIndex,
                          idx != lastScrolledIndex,
                          idx < analysisService.segments.count else { return }
                    lastScrolledIndex = idx
                    // Use non-animated scroll to avoid fighting user gestures
                    proxy.scrollTo(analysisService.segments[idx].id, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Time formatting (shared)

/// Format seconds as MM:SS.s (e.g. 01:23.4)
func formatTime(_ seconds: Double) -> String {
    let totalSeconds = max(0, seconds)
    let minutes = Int(totalSeconds) / 60
    let secs = totalSeconds.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%04.1f", minutes, secs)
}

/// Parse MM:SS.s format back to seconds. Returns nil if invalid.
func parseTime(_ string: String) -> Double? {
    let parts = string.split(separator: ":")
    guard parts.count == 2,
          let minutes = Double(parts[0]),
          let secs = Double(parts[1]),
          minutes >= 0, secs >= 0, secs < 60 else {
        return nil
    }
    return minutes * 60 + secs
}

/// Editable time field that displays and parses MM:SS.s format.
struct TimeField: View {
    @Binding var seconds: Double
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("00:00.0", text: $text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textFieldStyle(.plain)
            .frame(width: 52)
            .focused($isFocused)
            .onAppear { text = formatTime(seconds) }
            .onChange(of: seconds) { _, newValue in
                if !isFocused { text = formatTime(newValue) }
            }
            .onSubmit {
                if let parsed = parseTime(text) {
                    seconds = parsed
                } else {
                    text = formatTime(seconds)
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    if let parsed = parseTime(text) {
                        seconds = parsed
                    } else {
                        text = formatTime(seconds)
                    }
                }
            }
    }
}

#Preview("With Segments") {
    @Previewable @State var service = AnalysisService()
    TranscriptEditorView(analysisService: service, onSeek: { _ in }, currentTime: 1.0)
        .frame(width: 350, height: 500)
        .preferredColorScheme(.dark)
        .onAppear {
            service.segments = [
                Segment(start: 0.5, end: 3.2, text: "안녕하세요, 오늘은 날씨가 좋습니다."),
                Segment(start: 5.0, end: 8.1, text: "테스트 세그먼트입니다.", isKept: false),
                Segment(start: 62.3, end: 65.7, text: "1분이 넘는 타임스탬프 예시"),
            ]
        }
}
