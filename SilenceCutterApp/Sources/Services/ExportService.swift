import Foundation

/// Generates export format strings from edited segment lists.
/// All generators are pure functions — no side effects, no file I/O.
struct ExportService {

    // MARK: - Frame Rate Tables

    /// Known frame rates → (numerator, denominator, FCP code)
    private static let frameRates: [(fps: Double, num: Int, den: Int, code: String)] = [
        (23.976, 1001, 24000, "2398"),
        (24.0,   100,  2400,  "24"),
        (25.0,   100,  2500,  "25"),
        (29.97,  1001, 30000, "2997"),
        (30.0,   100,  3000,  "30"),
        (50.0,   100,  5000,  "50"),
        (59.94,  1001, 60000, "5994"),
        (60.0,   100,  6000,  "60"),
    ]

    private static func getFrameInfo(fps: Double) -> (num: Int, den: Int, code: String) {
        for rate in frameRates {
            if abs(fps - rate.fps) < 0.05 {
                return (rate.num, rate.den, rate.code)
            }
        }
        // Fallback: integer fps
        let ifps = Int(round(fps))
        return (100, ifps * 100, "\(ifps)")
    }

    /// Snap seconds to nearest frame boundary using integer arithmetic.
    /// Returns (numerator, denominator) of the rational time.
    private static func snapToFrame(seconds: Double, frameNum: Int, frameDen: Int) -> (Int, Int) {
        // frame_dur = frameNum / frameDen
        // frames = round(seconds / frame_dur) = round(seconds * frameDen / frameNum)
        let frames = Int(round(seconds * Double(frameDen) / Double(frameNum)))
        // result = frames * frameNum / frameDen
        let num = frames * frameNum
        let den = frameDen
        // Simplify by GCD
        let g = gcd(abs(num), den)
        return (num / g, den / g)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    private static func rationalStr(_ num: Int, _ den: Int) -> String {
        if num == 0 { return "0s" }
        return "\(num)/\(den)s"
    }

    private static func rationalStr(_ pair: (Int, Int)) -> String {
        rationalStr(pair.0, pair.1)
    }

    /// Add two rational times: a/b + c/d
    private static func addRational(_ a: (Int, Int), _ b: (Int, Int)) -> (Int, Int) {
        let num = a.0 * b.1 + b.0 * a.1
        let den = a.1 * b.1
        let g = gcd(abs(num), den)
        return (num / g, den / g)
    }

    /// Subtract two rational times: a/b - c/d
    private static func subRational(_ a: (Int, Int), _ b: (Int, Int)) -> (Int, Int) {
        let num = a.0 * b.1 - b.0 * a.1
        let den = a.1 * b.1
        let g = gcd(abs(num), den)
        return (num / g, den / g)
    }

    // MARK: - SRT

    /// Generates an SRT subtitle string from kept segments.
    /// Timecodes are remapped to the edited timeline (gaps removed).
    static func generateSRT(segments: [Segment]) -> String {
        let kept = segments.filter(\.isKept)
        guard !kept.isEmpty else { return "" }

        var offset: Double = 0
        return kept.enumerated().map { index, segment in
            let idx = index + 1
            let duration = segment.end - segment.start
            let start = srtTimecode(offset)
            let end = srtTimecode(offset + duration)
            offset += duration
            return "\(idx)\n\(start) --> \(end)\n\(segment.exportText)"
        }.joined(separator: "\n\n")
    }

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

    /// Generates FCPXML v1.13 from kept segments, matching Python fcpxml.py output.
    static func generateFCPXML(segments: [Segment], videoInfo: VideoInfo, videoURL: URL) -> String {
        let kept = segments.filter(\.isKept)
        let fps = videoInfo.fps
        let (frameNum, frameDen, fpsCode) = getFrameInfo(fps: fps)
        let formatName = "FFVideoFormat\(videoInfo.width)x\(videoInfo.height)p\(fpsCode)"

        // Compute total duration
        var totalDur = (0, 1)
        for seg in kept {
            let srcStart = snapToFrame(seconds: seg.start, frameNum: frameNum, frameDen: frameDen)
            let srcEnd = snapToFrame(seconds: seg.end, frameNum: frameNum, frameDen: frameDen)
            let clipDur = subRational(srcEnd, srcStart)
            if clipDur.0 > 0 {
                totalDur = addRational(totalDur, clipDur)
            }
        }

        let videoDur = snapToFrame(seconds: videoInfo.duration, frameNum: frameNum, frameDen: frameDen)

        let formatId = "r1"
        let assetId = "r2"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.13">
          <resources>
            <format id="\(formatId)" name="\(formatName)" \
        frameDuration="\(frameNum)/\(frameDen)s" \
        width="\(videoInfo.width)" height="\(videoInfo.height)" \
        colorSpace="1-1-1 (Rec. 709)"/>
            <asset id="\(assetId)" name="\(videoURL.deletingPathExtension().lastPathComponent)" \
        start="0s" \
        duration="\(rationalStr(videoDur))" \
        hasVideo="1" hasAudio="1" format="\(formatId)">
              <media-rep kind="original-media" src="\(videoURL.absoluteString)"/>
            </asset>
          </resources>
          <library>
            <event name="SilenceCutter Export">
              <project name="SilenceCutter Export">
                <sequence format="\(formatId)" duration="\(rationalStr(totalDur))" \
        tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                  <spine>

        """

        var offset = (0, 1)
        for seg in kept {
            let srcStart = snapToFrame(seconds: seg.start, frameNum: frameNum, frameDen: frameDen)
            let srcEnd = snapToFrame(seconds: seg.end, frameNum: frameNum, frameDen: frameDen)
            let clipDur = subRational(srcEnd, srcStart)

            guard clipDur.0 > 0 else { continue }

            let clipName = xmlEscape(String(seg.exportText.prefix(30)))

            xml += """
                        <asset-clip ref="\(assetId)" \
            offset="\(rationalStr(offset))" \
            name="\(clipName)" \
            start="\(rationalStr(srcStart))" \
            duration="\(rationalStr(clipDur))" \
            tcFormat="NDF"/>\n
            """
            offset = addRational(offset, clipDur)
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

    // MARK: - iTT

    /// Generates an iTT (TTML-based) subtitle string from kept segments.
    /// Matches Python itt.py output with proper styling, layout, and region.
    /// Timecodes are remapped to the edited timeline (gaps removed).
    static func generateITT(segments: [Segment], fps: Double = 24.0) -> String {
        let kept = segments.filter(\.isKept)

        // Compute frameRate and frameRateMultiplier for FCP compatibility
        let roundedFps = Int(round(fps))
        let isNTSC = abs(fps - Double(roundedFps)) > 0.01
        let frameRate = roundedFps
        let multiplier = isNTSC ? "999 1000" : "1 1"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:tts="http://www.w3.org/ns/ttml#styling"
            xmlns:ttp="http://www.w3.org/ns/ttml#parameter"
            xmlns:ittp="http://www.w3.org/ns/ttml/profile/imsc1#parameter"
            xml:lang="ko"
            ttp:frameRate="\(frameRate)"
            ttp:frameRateMultiplier="\(multiplier)"
            ttp:tickRate="10000000">
          <head>
            <styling>
              <style xml:id="default"
                     tts:fontFamily="Helvetica"
                     tts:fontSize="100%"
                     tts:color="white"
                     tts:textAlign="center"/>
            </styling>
            <layout>
              <region xml:id="bottom"
                      tts:origin="0% 80%"
                      tts:extent="100% 20%"
                      tts:displayAlign="after"
                      tts:writingMode="lrtb"/>
            </layout>
          </head>
          <body>
            <div>

        """

        var offset: Double = 0
        for segment in kept {
            let duration = segment.end - segment.start
            let begin = ittTimecode(offset)
            let end = ittTimecode(offset + duration)
            let escapedText = xmlEscape(segment.exportText)
            xml += "      <p begin=\"\(begin)\" end=\"\(end)\" region=\"bottom\" style=\"default\">\(escapedText)</p>\n"
            offset += duration
        }

        xml += """
            </div>
          </body>
        </tt>
        """

        return xml
    }

    private static func ittTimecode(_ seconds: Double) -> String {
        let totalMs = Int(round(seconds * 1000))
        let ms = totalMs % 1000
        let totalSecs = totalMs / 1000
        let s = totalSecs % 60
        let m = (totalSecs / 60) % 60
        let h = totalSecs / 3600
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
