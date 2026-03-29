import SwiftUI

/// A single clip card in Vrew style — shows segment as a visual block.
/// Discarded clips collapse to a thin gray bar with restore action.
struct ClipCardView: View {
    let index: Int
    @Binding var segment: Segment
    var onSeek: (TimeInterval) -> Void
    var onSplit: () -> Void
    var onSplitAtWord: ((Int) -> Void)? = nil
    var onMerge: (() -> Void)?
    var isActive: Bool = false

    var body: some View {
        if segment.isKept {
            keptCard
        } else {
            discardedBar
        }
    }

    // MARK: - Kept clip (full card)

    private var keptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerSection
            if !segment.words.isEmpty {
                videoEditSection
            }
            subtitleEditSection
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.cyan.opacity(0.08) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.cyan.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
        )
        .contextMenu {
            Button("클립 분할") { onSplit() }
            if let onMerge {
                Button("다음 클립과 병합") { onMerge() }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 6) {
            Text("클립 \(index + 1)")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            Spacer()

            TimeField(seconds: $segment.start)
            Text("–")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            TimeField(seconds: $segment.end)

            Button {
                onSeek(segment.start)
            } label: {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: $segment.isKept)
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
    }

    // MARK: - Video edit section

    private var videoEditSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "film")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("영상편집")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            WordFlowView(words: $segment.words, onSplitAt: onSplitAtWord)
        }
    }

    // MARK: - Subtitle edit section

    private var subtitleEditSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "text.quote")
                    .font(.caption2)
                    .foregroundStyle(.cyan.opacity(0.7))
                Text("자막수정")
                    .font(.caption2)
                    .foregroundStyle(.cyan.opacity(0.7))
            }
            TextField("자막 텍스트", text: $segment.text, axis: .vertical)
                .font(.body)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: segment.text) { _, newText in
                    syncWordsFromText(newText)
                }
        }
    }

    // MARK: - Discarded clip (collapsed bar)

    private var discardedBar: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.red.opacity(0.3))
                .frame(width: 3, height: 16)

            Text("클립 \(index + 1) — 삭제됨")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(formatTimeBrief(segment.start))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            Spacer()

            Button("복구") {
                segment.isKept = true
            }
            .font(.caption2)
            .buttonStyle(.plain)
            .foregroundStyle(.cyan)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func syncWordsFromText(_ newText: String) {
        guard !segment.words.isEmpty else { return }
        let newWords = newText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let oldWords = segment.words

        if newWords.count == oldWords.count {
            for i in newWords.indices {
                if segment.words[i].text != newWords[i] {
                    segment.words[i] = Word(
                        id: oldWords[i].id,
                        text: newWords[i],
                        start: oldWords[i].start,
                        end: oldWords[i].end,
                        isKept: oldWords[i].isKept
                    )
                }
            }
        } else {
            let totalStart = oldWords.first?.start ?? segment.start
            let totalEnd = oldWords.last?.end ?? segment.end
            let totalDur = totalEnd - totalStart
            let wordDur = newWords.isEmpty ? 0 : totalDur / Double(newWords.count)
            segment.words = newWords.enumerated().map { i, text in
                Word(text: text, start: totalStart + Double(i) * wordDur, end: totalStart + Double(i + 1) * wordDur)
            }
        }
    }
}

// MARK: - Brief time format

private func formatTimeBrief(_ seconds: Double) -> String {
    let totalSeconds = max(0, seconds)
    let minutes = Int(totalSeconds) / 60
    let secs = totalSeconds.truncatingRemainder(dividingBy: 60)
    return String(format: "%d:%04.1f", minutes, secs)
}
