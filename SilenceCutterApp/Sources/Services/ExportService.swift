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
    static func generateFCPXML(segments: [Segment], videoInfo: VideoInfo, videoURL: URL, fontSize: Int = 42, maxSubtitleChars: Int = 20) -> String {
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
            <effect id="r3" name="Basic Title" uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
          </resources>
          <library>
            <event name="SilenceCutter Export">
              <project name="SilenceCutter Export">
                <sequence format="\(formatId)" duration="\(rationalStr(totalDur))" \
        tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                  <spine>

        """

        var offset = (0, 1)
        var tsCounter = 0
        for (_, seg) in kept.enumerated() {
            let srcStart = snapToFrame(seconds: seg.start, frameNum: frameNum, frameDen: frameDen)
            let srcEnd = snapToFrame(seconds: seg.end, frameNum: frameNum, frameDen: frameDen)
            let clipDur = subRational(srcEnd, srcStart)

            guard clipDur.0 > 0 else { continue }

            // Build subtitle titles inside asset-clip
            // Use word-level timing when available for accurate subtitle sync.
            let wordChunks = seg.words.isEmpty
                ? subtitleChunksFromText(seg.exportText, maxChars: maxSubtitleChars, segStart: seg.start, segEnd: seg.end)
                : subtitleChunksFromWords(seg.words.filter(\.isKept), maxChars: maxSubtitleChars)

            // Clip name = first subtitle chunk (matches what FCP shows in timeline)
            let clipName = xmlEscape(wordChunks.first?.text ?? String(seg.exportText.prefix(30)))

            if wordChunks.isEmpty {
                // No subtitle — self-closing asset-clip
                xml += """
                            <asset-clip ref="\(assetId)" \
                offset="\(rationalStr(offset))" \
                name="\(clipName)" \
                start="\(rationalStr(srcStart))" \
                duration="\(rationalStr(clipDur))" \
                tcFormat="NDF"/>\n
                """
            } else {
                // Asset-clip with subtitle titles
                xml += """
                            <asset-clip ref="\(assetId)" \
                offset="\(rationalStr(offset))" \
                name="\(clipName)" \
                start="\(rationalStr(srcStart))" \
                duration="\(rationalStr(clipDur))" \
                tcFormat="NDF">\n
                """

                // Distribute subtitle chunks with word-level timing
                for wc in wordChunks {
                    tsCounter += 1
                    let tsId = "ts\(tsCounter)"

                    var chunkStart = snapToFrame(seconds: wc.start, frameNum: frameNum, frameDen: frameDen)
                    var chunkEnd = snapToFrame(seconds: wc.end, frameNum: frameNum, frameDen: frameDen)

                    // Clamp to clip boundaries
                    if chunkStart.0 * srcStart.1 < srcStart.0 * chunkStart.1 { chunkStart = srcStart }
                    if chunkEnd.0 * srcEnd.1 > srcEnd.0 * chunkEnd.1 { chunkEnd = srcEnd }

                    let chunkDur = subRational(chunkEnd, chunkStart)
                    guard chunkDur.0 > 0 else { continue }

                    let escapedChunk = xmlEscape(wc.text)

                    xml += """
                                <title ref="r3" lane="1" \
                    offset="\(rationalStr(chunkStart))" \
                    name="\(escapedChunk)" \
                    start="3600s" \
                    duration="\(rationalStr(chunkDur))">
                                  <text><text-style ref="\(tsId)">\(escapedChunk)</text-style></text>
                                  <text-style-def id="\(tsId)">
                                    <text-style font="Helvetica" fontSize="\(fontSize)" fontColor="1 1 1 1" bold="1" shadowColor="0 0 0 0.75" shadowOffset="3 315" alignment="center"/>
                                  </text-style-def>
                                </title>\n
                    """
                }

                xml += "                </asset-clip>\n"
            }
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

    // MARK: - Subtitle splitting

    /// Split subtitle text into chunks of maxChars, preferring natural break points.
    private static func splitSubtitle(_ text: String, maxChars: Int = 20) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.count > maxChars else { return [text] }

        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var chunks: [String] = []
        var current = ""

        for word in words {
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count > maxChars && !current.isEmpty {
                chunks.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    // MARK: - Word-based subtitle chunking (accurate timing)

    /// A subtitle chunk with text and precise timing from word timestamps.
    struct SubtitleChunk {
        let text: String
        let start: Double
        let end: Double
    }

    /// Split words into subtitle chunks using word-level timing.
    /// Mirrors Python's _split_subtitle logic — breaks at natural points or maxChars.
    private static func subtitleChunksFromWords(_ words: [Word], maxChars: Int) -> [SubtitleChunk] {
        guard !words.isEmpty else { return [] }

        var chunks: [SubtitleChunk] = []
        var currentWords: [Word] = []
        var currentText = ""

        for (i, word) in words.enumerated() {
            let candidate = currentText.isEmpty ? word.text : "\(currentText) \(word.text)"
            currentWords.append(word)
            currentText = candidate

            let isLast = (i == words.count - 1)
            var shouldBreak = false

            if isLast {
                shouldBreak = true
            } else if isNaturalBreak(word.text) && currentText.count >= 6 {
                shouldBreak = true
            } else if currentText.count >= maxChars {
                // Check if next word is short (≤3 chars) — include it to avoid orphan
                // But enforce hard limit at maxChars + 8 to prevent runaway accumulation
                let nextWord = words[i + 1].text
                if nextWord.count <= 3 && currentText.count < maxChars + 8 {
                    // Don't break yet — include the short next word
                } else {
                    shouldBreak = true
                }
            }

            if shouldBreak && !currentText.isEmpty {
                chunks.append(SubtitleChunk(
                    text: currentText,
                    start: currentWords.first!.start,
                    end: currentWords.last!.end
                ))
                currentWords = []
                currentText = ""
            }
        }

        return chunks
    }

    /// Fallback: create subtitle chunks from plain text when words are unavailable.
    /// Evenly distributes timing across the segment.
    private static func subtitleChunksFromText(_ text: String, maxChars: Int, segStart: Double, segEnd: Double) -> [SubtitleChunk] {
        let textChunks = splitSubtitle(text, maxChars: maxChars)
        guard !textChunks.isEmpty else { return [] }

        let segDur = segEnd - segStart
        let count = textChunks.count
        return textChunks.enumerated().map { i, chunk in
            SubtitleChunk(
                text: chunk,
                start: segStart + segDur * Double(i) / Double(count),
                end: segStart + segDur * Double(i + 1) / Double(count)
            )
        }
    }

    /// Check if a word ends at a natural sentence/clause break.
    private static let sentenceEndPattern = try! NSRegularExpression(pattern: "[.!?。，,]$")
    private static let clauseEndPattern = try! NSRegularExpression(pattern: "(요|다|까|죠|고|서|며|면|지만|는데|니까|거든|래요|세요|습니다|합니다|했고|었고|였고|인데|해서|라서|더니|으니|하고)$")

    private static func isNaturalBreak(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if sentenceEndPattern.firstMatch(in: text, range: range) != nil { return true }
        if clauseEndPattern.firstMatch(in: text, range: range) != nil { return true }
        return false
    }
}
