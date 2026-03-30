import SwiftUI

/// Renders a horizontal timeline bar showing voiced/silence regions as colored blocks,
/// a playhead tracking `currentTime`, and click-to-seek interaction.
struct TimelineBarView: View {
    let segments: [Segment]
    let duration: TimeInterval
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void

    // MARK: - Region model

    private enum RegionType {
        case voiced(isKept: Bool)
        case silence
    }

    private struct Region {
        let start: Double
        let end: Double
        let type: RegionType
    }

    // MARK: - Body

    var body: some View {
        if duration <= 0 {
            // Guard: no valid duration — show empty placeholder
            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .overlay(
                    Text("No timeline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )
        } else {
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                let regions = buildRegions()

                ZStack(alignment: .leading) {
                    // Region blocks via Canvas
                    Canvas { context, size in
                        for region in regions {
                            let x = (region.start / duration) * size.width
                            let w = ((region.end - region.start) / duration) * size.width
                            let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                            let color: Color = switch region.type {
                            case .voiced(let isKept):
                                isKept ? .cyan : .red.opacity(0.5)
                            case .silence:
                                .gray.opacity(0.2)
                            }
                            context.fill(Path(rect), with: .color(color))
                        }
                    }

                    // Playhead
                    let clampedTime = min(max(currentTime, 0), duration)
                    let playheadX = (clampedTime / duration) * totalWidth

                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .offset(x: playheadX)
                        .animation(.linear(duration: 0.1), value: currentTime)
                }
                .contentShape(Rectangle()) // make entire area tappable
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let fraction = min(max(value.location.x / totalWidth, 0), 1)
                            let seekTime = fraction * duration
                            onSeek(seekTime)
                        }
                )
            }
        }
    }

    // MARK: - Region computation

    /// Build a flat list of regions covering [0, duration], filling gaps with silence.
    private func buildRegions() -> [Region] {
        guard duration > 0 else { return [] }

        let sorted = segments.sorted { $0.start < $1.start }
        var regions: [Region] = []
        var cursor: Double = 0

        for seg in sorted {
            // Fill gap before this segment with silence
            if seg.start > cursor {
                regions.append(Region(start: cursor, end: seg.start, type: .silence))
            }
            // Voiced region
            regions.append(Region(start: seg.start, end: seg.end, type: .voiced(isKept: seg.isKept)))
            cursor = seg.end
        }

        // Fill trailing gap
        if cursor < duration {
            regions.append(Region(start: cursor, end: duration, type: .silence))
        }

        return regions
    }
}

// MARK: - Preview

#Preview("With segments") {
    TimelineBarView(
        segments: [
            Segment(start: 0.5, end: 3.0, text: "Hello world", isKept: true),
            Segment(start: 4.0, end: 7.5, text: "Second segment", isKept: false),
            Segment(start: 8.0, end: 10.0, text: "Third segment", isKept: true),
        ],
        duration: 12.0,
        currentTime: 5.0,
        onSeek: { print("Seek to \($0)") }
    )
    .frame(height: 60)
    .padding()
}

#Preview("Empty segments") {
    TimelineBarView(
        segments: [],
        duration: 10.0,
        currentTime: 0,
        onSeek: { _ in }
    )
    .frame(height: 60)
    .padding()
}

#Preview("Zero duration") {
    TimelineBarView(
        segments: [],
        duration: 0,
        currentTime: 0,
        onSeek: { _ in }
    )
    .frame(height: 60)
    .padding()
}
