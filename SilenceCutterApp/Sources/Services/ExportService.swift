import Foundation

/// Generates export format strings from edited segment lists.
/// All generators are pure functions — no side effects, no file I/O.
struct ExportService {

    // MARK: - SRT

    /// Generates an SRT subtitle string from kept segments.
    /// Uses 1-based indexing and comma decimal separator per SRT spec.
    static func generateSRT(segments: [Segment]) -> String {
        let kept = segments.filter(\.isKept)
        guard !kept.isEmpty else { return "" }

        return kept.enumerated().map { index, segment in
            let idx = index + 1
            let start = srtTimecode(segment.start)
            let end = srtTimecode(segment.end)
            return "\(idx)\n\(start) --> \(end)\n\(segment.text)"
        }.joined(separator: "\n\n")
    }

    /// Formats seconds as `HH:MM:SS,mmm` (comma decimal separator).
    private static func srtTimecode(_ seconds: Double) -> String {
        let totalMs = Int(round(seconds * 1000))
        let ms = totalMs % 1000
        let totalSecs = totalMs / 1000
        let s = totalSecs % 60
        let m = (totalSecs / 60) % 60
        let h = totalSecs / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - FCPXML

    /// Generates FCPXML v1.9 from kept segments with proper rational time notation.
    static func generateFCPXML(segments: [Segment], videoInfo: VideoInfo, videoURL: URL) -> String {
        let kept = segments.filter(\.isKept)
        let fps = videoInfo.fps
        let timebase = computeTimebase(fps: fps)
        let frameDuration = computeFrameDuration(fps: fps, timebase: timebase)

        // Total output duration = sum of kept segment durations
        let totalDuration = kept.reduce(0.0) { $0 + $1.duration }
        let totalDurationRational = rationalTime(totalDuration, timebase: timebase)

        let formatId = "r1"
        let assetId = "r2"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.9">
          <resources>
            <format id="\(formatId)" name="FFVideoFormat\(videoInfo.width)x\(videoInfo.height)" \
        frameDuration="\(frameDuration)" width="\(videoInfo.width)" height="\(videoInfo.height)"/>
            <asset id="\(assetId)" src="\(videoURL.absoluteString)" start="0/1s" \
        duration="\(rationalTime(videoInfo.duration, timebase: timebase))" \
        format="\(formatId)"/>
          </resources>
          <library>
            <event name="SilenceCutter Export">
              <project name="Edited">
                <sequence format="\(formatId)" duration="\(totalDurationRational)" \
        tcStart="0/1s" tcFormat="NDF">
                  <spine>

        """

        var offset: Double = 0.0
        for segment in kept {
            let offsetRational = rationalTime(offset, timebase: timebase)
            let startRational = rationalTime(segment.start, timebase: timebase)
            let durationRational = rationalTime(segment.duration, timebase: timebase)
            xml += """
                        <asset-clip ref="\(assetId)" \
            offset="\(offsetRational)" \
            start="\(startRational)" \
            duration="\(durationRational)" \
            tcFormat="NDF"/>\n
            """
            offset += segment.duration
        }

        xml += """
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>
        """

        return xml
    }

    /// Computes the timebase denominator for rational time notation.
    /// Integer fps (24, 25, 30, 60) → timebase = fps.
    /// NTSC rates (23.976, 29.97, 59.94) → timebase = round(fps) * 1000.
    private static func computeTimebase(fps: Double) -> Int {
        let rounded = Int(round(fps))
        let isNTSC = abs(fps - Double(rounded)) > 0.01
        return isNTSC ? rounded * 1000 : rounded
    }

    /// Computes the frame duration string for the `<format>` element.
    /// NTSC: `1001/<timebase>s`, integer: `100/<timebase>s`.
    private static func computeFrameDuration(fps: Double, timebase: Int) -> String {
        let rounded = Int(round(fps))
        let isNTSC = abs(fps - Double(rounded)) > 0.01
        if isNTSC {
            return "1001/\(timebase)s"
        } else {
            return "100/\(timebase)s"
        }
    }

    /// Converts seconds to rational time notation: `<ticks>/<timebase>s`.
    private static func rationalTime(_ seconds: Double, timebase: Int) -> String {
        let ticks = Int(round(seconds * Double(timebase)))
        return "\(ticks)/\(timebase)s"
    }

    // MARK: - iTT

    /// Generates an iTT (TTML-based) subtitle string from kept segments.
    /// Uses dot decimal separator per TTML spec.
    static func generateITT(segments: [Segment]) -> String {
        let kept = segments.filter(\.isKept)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="ko">
          <body>
            <div>

        """

        for segment in kept {
            let begin = ittTimecode(segment.start)
            let end = ittTimecode(segment.end)
            let escapedText = xmlEscape(segment.text)
            xml += "      <p begin=\"\(begin)\" end=\"\(end)\">\(escapedText)</p>\n"
        }

        xml += """
            </div>
          </body>
        </tt>
        """

        return xml
    }

    /// Formats seconds as `HH:MM:SS.mmm` (dot decimal separator).
    private static func ittTimecode(_ seconds: Double) -> String {
        let totalMs = Int(round(seconds * 1000))
        let ms = totalMs % 1000
        let totalSecs = totalMs / 1000
        let s = totalSecs % 60
        let m = (totalSecs / 60) % 60
        let h = totalSecs / 3600
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    /// Escapes special XML characters in text content.
    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
