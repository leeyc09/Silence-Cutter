import Foundation

/// Orchestrates the Python VAD+ASR analysis pipeline via PythonBridge.
///
/// Usage:
/// ```swift
/// let service = AnalysisService()
/// await service.analyze(videoURL: someURL)
/// // service.segments now contains results
/// ```
@MainActor
@Observable
final class AnalysisService {

    // MARK: - Published state

    /// Transcribed segments from the last analysis run.
    var segments: [Segment] = []

    /// Video metadata from the last analysis run.
    var videoInfo: VideoInfo?

    /// Timeline duration for resub (may differ from video duration due to silence cuts).
    /// nil for fresh analyses where timeline == source.
    var timelineDuration: Double?

    /// Whether an analysis is currently in progress.
    private(set) var isAnalyzing = false

    /// Current progress from the Python pipeline (forwarded from bridge).
    var progress: ProgressInfo? {
        bridge?.currentProgress
    }

    /// Last error message, if the analysis failed.
    private(set) var error: String?

    // MARK: - Internal

    /// The bridge instance used during analysis. Created per-run.
    /// Exposed as internal so progress can be read from computed property.
    @ObservationIgnored
    private var bridge: PythonBridge?

    /// The async analysis task — kept so it can be cancelled.
    @ObservationIgnored
    private var analysisTask: Task<Void, Never>?

    // MARK: - Analysis

    /// Run the full VAD+ASR analysis pipeline on a video file.
    ///
    /// - Parameters:
    ///   - videoURL: Local file URL of the video to analyze.
    ///   - environment: A ready PythonEnvironment that provides paths.
    ///                  If nil, falls back to legacy cwd walk-up discovery.
    ///   - settings: Analysis settings (language, VAD params, etc.).
    ///               If nil, uses defaults.
    func analyze(videoURL: URL, environment: PythonEnvironment? = nil, settings: AnalysisSettings? = nil) async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        error = nil
        segments = []
        videoInfo = nil
        timelineDuration = nil

        let newBridge = PythonBridge()
        bridge = newBridge

        // Configure bridge paths from environment or legacy discovery
        if case .ready(let pythonPath, let modulePath) = environment?.state {
            newBridge.pythonPath = pythonPath
            newBridge.projectRoot = modulePath
        } else {
            // Legacy fallback: walk up from cwd looking for silence_cutter/
            let fm = FileManager.default
            var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
            var projectRoot = dir.path
            for _ in 0..<5 {
                let candidate = dir.appendingPathComponent("silence_cutter").path
                if fm.fileExists(atPath: candidate) {
                    projectRoot = dir.path
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
            newBridge.projectRoot = projectRoot
        }

        do {
            try newBridge.start()
            print("[AnalysisService] Python bridge started, project root: \(newBridge.projectRoot)")

            let response = try await newBridge.call(
                "analyze",
                params: [
                    "video_path": .string(videoURL.path),
                    "language": .string(settings?.language ?? "Korean"),
                    "asr_model": .string(settings?.asrModel.rawValue ?? "mlx-community/Qwen3-ASR-0.6B-8bit"),
                    "threshold": .double(settings?.vadThreshold ?? 0.5),
                    "min_speech_ms": .int(settings?.minSpeechMs ?? 250),
                    "min_silence_ms": .int(settings?.minSilenceMs ?? 200),
                    "speech_pad_ms": .int(settings?.speechPadMs ?? 100),
                    "max_segment_seconds": .double(settings?.maxSegmentSeconds ?? 8.0),
                    "max_subtitle_chars": .int(settings?.maxSubtitleChars ?? 20),
                ],
                timeout: 600,  // 10 min — long videos can take time
                as: AnalyzeResponse.self
            )

            self.segments = response.segments
            self.videoInfo = response.videoInfo
            self.timelineDuration = response.timelineDuration

            print("[AnalysisService] ✅ Analysis complete: \(segments.count) segments")

            newBridge.stop()
        } catch {
            let msg = String(describing: error)
            if Task.isCancelled {
                self.error = nil  // 사용자가 취소한 경우 에러 표시 안 함
                print("[AnalysisService] ⛔ Analysis cancelled")
            } else {
                self.error = msg
                print("[AnalysisService] ❌ Analysis failed: \(msg)")
            }
            newBridge.stop()
        }

        bridge = nil
        isAnalyzing = false
        analysisTask = nil
    }

    /// Cancel the currently running analysis.
    func cancelAnalysis() {
        guard isAnalyzing else { return }
        analysisTask?.cancel()
        bridge?.stop()
        bridge = nil
        isAnalyzing = false
        analysisTask = nil
        error = nil
        print("[AnalysisService] ⛔ Analysis cancelled by user")
    }

    /// Start analysis in a tracked Task (enables cancellation).
    func startAnalysis(videoURL: URL, environment: PythonEnvironment? = nil, settings: AnalysisSettings? = nil) {
        analysisTask = Task {
            await analyze(videoURL: videoURL, environment: environment, settings: settings)
        }
    }

    /// Start resub (re-transcribe from edited FCPXML) in a tracked Task.
    func startResub(fcpxmlURL: URL, environment: PythonEnvironment? = nil, settings: AnalysisSettings? = nil) {
        analysisTask = Task {
            await resub(fcpxmlURL: fcpxmlURL, environment: environment, settings: settings)
        }
    }

    /// Re-transcribe an edited FCPXML — reads clip boundaries, runs ASR on each clip.
    func resub(fcpxmlURL: URL, environment: PythonEnvironment? = nil, settings: AnalysisSettings? = nil) async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        error = nil
        segments = []
        videoInfo = nil
        timelineDuration = nil

        let newBridge = PythonBridge()
        bridge = newBridge

        if case .ready(let pythonPath, let modulePath) = environment?.state {
            newBridge.pythonPath = pythonPath
            newBridge.projectRoot = modulePath
        } else {
            let fm = FileManager.default
            var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
            var projectRoot = dir.path
            for _ in 0..<5 {
                let candidate = dir.appendingPathComponent("silence_cutter").path
                if fm.fileExists(atPath: candidate) {
                    projectRoot = dir.path
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
            newBridge.projectRoot = projectRoot
        }

        do {
            try newBridge.start()
            print("[AnalysisService] Python bridge started for resub")

            let response = try await newBridge.call(
                "resub",
                params: [
                    "fcpxml_path": .string(fcpxmlURL.path),
                    "language": .string(settings?.language ?? "Korean"),
                    "asr_model": .string(settings?.asrModel.rawValue ?? "mlx-community/Qwen3-ASR-0.6B-8bit"),
                    "aligner_model": .string("mlx-community/Qwen3-ForcedAligner-0.6B-8bit"),
                    "max_segment_seconds": .double(settings?.maxSegmentSeconds ?? 8.0),
                ],
                timeout: 600,
                as: AnalyzeResponse.self
            )

            self.segments = response.segments
            self.videoInfo = response.videoInfo
            self.timelineDuration = response.timelineDuration

            print("[AnalysisService] ✅ Resub complete: \(segments.count) segments")

            newBridge.stop()
        } catch {
            let msg = String(describing: error)
            if Task.isCancelled {
                self.error = nil
                print("[AnalysisService] ⛔ Resub cancelled")
            } else {
                self.error = msg
                print("[AnalysisService] ❌ Resub failed: \(msg)")
            }
            newBridge.stop()
        }

        bridge = nil
        isAnalyzing = false
        analysisTask = nil
    }

    // MARK: - Retranscribe to file (no UI load)

    /// Re-transcribe an edited FCPXML and save directly to a new file.
    /// Does NOT load segments into the UI — runs ASR and writes output FCPXML.
    /// Uses a separate bridge instance so it doesn't conflict with isAnalyzing.
    func retranscribeToFile(
        fcpxmlURL: URL,
        outputURL: URL,
        environment: PythonEnvironment? = nil,
        language: String = "Korean",
        asrModel: String = "mlx-community/Qwen3-ASR-0.6B-8bit",
        fontSize: Int = 42,
        maxSubtitleChars: Int = 20,
        exportITT: Bool = false
    ) async throws -> RetranscribeResponse {
        let newBridge = PythonBridge()
        // Expose bridge for progress reading
        retranscribeBridge = newBridge

        if case .ready(let pythonPath, let modulePath) = environment?.state {
            newBridge.pythonPath = pythonPath
            newBridge.projectRoot = modulePath
        } else {
            let fm = FileManager.default
            var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
            var projectRoot = dir.path
            for _ in 0..<5 {
                let candidate = dir.appendingPathComponent("silence_cutter").path
                if fm.fileExists(atPath: candidate) {
                    projectRoot = dir.path
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
            newBridge.projectRoot = projectRoot
        }

        defer {
            newBridge.stop()
            retranscribeBridge = nil
        }

        try newBridge.start()
        print("[AnalysisService] Python bridge started for retranscribe")

        let response = try await newBridge.call(
            "retranscribe_to_file",
            params: [
                "fcpxml_path": .string(fcpxmlURL.path),
                "output_path": .string(outputURL.path),
                "language": .string(language),
                "asr_model": .string(asrModel),
                "aligner_model": .string("mlx-community/Qwen3-ForcedAligner-0.6B-8bit"),
                "font_size": .int(fontSize),
                "max_subtitle_chars": .int(maxSubtitleChars),
                "export_itt": .bool(exportITT),
            ],
            timeout: 600,
            as: RetranscribeResponse.self
        )

        print("[AnalysisService] ✅ Retranscribe complete: \(response.outputPath)")
        return response
    }

    /// Progress from the retranscribe bridge (separate from analysis bridge).
    var retranscribeProgress: ProgressInfo? {
        retranscribeBridge?.currentProgress
    }

    /// Cancel a running retranscribe operation.
    func cancelRetranscribe() {
        retranscribeBridge?.stop()
        retranscribeBridge = nil
    }

    @ObservationIgnored
    private nonisolated(unsafe) var retranscribeBridge: PythonBridge?

    /// Split a segment at a given word index. Words before the index stay in the original,
    /// words from the index onward go to a new segment inserted after.
    /// If no words exist, splits at the midpoint of the time range.
    func splitSegment(at segmentIndex: Int, wordIndex: Int? = nil) {
        guard segmentIndex >= 0, segmentIndex < segments.count else { return }
        let segment = segments[segmentIndex]

        if let wi = wordIndex, !segment.words.isEmpty, wi > 0, wi < segment.words.count {
            // Split at word boundary
            let firstWords = Array(segment.words[..<wi])
            let secondWords = Array(segment.words[wi...])
            let splitTime = secondWords[0].start

            var first = segment
            first.words = firstWords
            first.end = splitTime
            first.text = firstWords.map(\.text).joined(separator: " ")

            let second = Segment(
                start: splitTime,
                end: segment.end,
                text: secondWords.map(\.text).joined(separator: " "),
                isKept: segment.isKept,
                words: secondWords
            )
            // Keep second's id fresh (already gets new UUID from init)

            segments[segmentIndex] = first
            segments.insert(second, at: segmentIndex + 1)
        } else {
            // No words or no valid word index — split at midpoint
            let mid = (segment.start + segment.end) / 2.0
            var first = segment
            first.end = mid
            first.text = segment.text

            let second = Segment(
                start: mid,
                end: segment.end,
                text: "",
                isKept: segment.isKept
            )

            segments[segmentIndex] = first
            segments.insert(second, at: segmentIndex + 1)
        }
    }

    /// Merge a segment with the next one. Combines text, words, and time ranges.
    func mergeWithNext(at segmentIndex: Int) {
        guard segmentIndex >= 0, segmentIndex < segments.count - 1 else { return }
        let current = segments[segmentIndex]
        let next = segments[segmentIndex + 1]

        var merged = current
        merged.end = next.end
        merged.text = [current.text, next.text].filter { !$0.isEmpty }.joined(separator: " ")
        merged.words = current.words + next.words
        // Keep isKept if either was kept
        merged.isKept = current.isKept || next.isKept

        segments[segmentIndex] = merged
        segments.remove(at: segmentIndex + 1)
    }

    /// Remove all discarded (isKept=false) segments from the list.
    /// Replace all occurrences of a search string in segment text and word text.
    func replaceAll(search: String, with replacement: String) {
        guard !search.isEmpty else { return }
        for i in segments.indices {
            segments[i].text = segments[i].text.replacingOccurrences(of: search, with: replacement)
            for j in segments[i].words.indices {
                segments[i].words[j] = Word(
                    id: segments[i].words[j].id,
                    text: segments[i].words[j].text.replacingOccurrences(of: search, with: replacement),
                    start: segments[i].words[j].start,
                    end: segments[i].words[j].end,
                    isKept: segments[i].words[j].isKept
                )
            }
        }
    }

    // MARK: - Auto-split

    /// Automatically split segments longer than maxDuration at the best word boundary.
    /// Prefers sentence-ending punctuation (.?!) boundaries, falls back to nearest word to midpoint.
    private func autoSplitLongSegments(maxDuration: Double) {
        var i = 0
        while i < segments.count {
            let seg = segments[i]
            if seg.duration > maxDuration && seg.words.count >= 2 {
                // Find best split point
                if let splitWordIndex = findBestSplitIndex(segment: seg, maxDuration: maxDuration) {
                    splitSegment(at: i, wordIndex: splitWordIndex)
                    // Don't advance i — check the first half again (it may still be too long)
                    continue
                }
            }
            i += 1
        }
    }

    /// Find the best word index to split a segment. Prefers sentence boundaries,
    /// falls back to the word nearest to the midpoint.
    private func findBestSplitIndex(segment: Segment, maxDuration: Double) -> Int? {
        let words = segment.words
        guard words.count >= 2 else { return nil }

        let mid = (segment.start + segment.end) / 2.0
        let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！"]

        // Look for sentence-ending punctuation nearest to midpoint
        var bestSentenceIdx: Int? = nil
        var bestSentenceDist = Double.infinity

        for (idx, word) in words.enumerated() {
            // Skip first and last — need at least 1 word on each side
            guard idx > 0, idx < words.count - 1 else { continue }
            if let lastChar = word.text.last, sentenceEnders.contains(lastChar) {
                let dist = abs(word.end - mid)
                if dist < bestSentenceDist {
                    bestSentenceDist = dist
                    bestSentenceIdx = idx + 1 // split AFTER this word
                }
            }
        }

        if let idx = bestSentenceIdx { return idx }

        // Fallback: split at word nearest to midpoint
        var bestIdx = 1
        var bestDist = Double.infinity
        for (idx, word) in words.enumerated() {
            guard idx > 0 else { continue }
            let dist = abs(word.start - mid)
            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
            }
        }
        return bestIdx
    }
}
