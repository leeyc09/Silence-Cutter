import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var bridge = PythonBridge()
    @State private var videoModel = VideoPlayerModel()
    @State private var analysisService = AnalysisService()
    @State private var bridgeStatus: String = ""
    @State private var isTesting = false
    @State private var showFindReplace = false

    var body: some View {
        NavigationSplitView {
            // Left panel — transcript / analysis
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "text.quote")
                        .foregroundStyle(.cyan)
                    Text("Transcript")
                        .font(.headline)
                }
                .padding(.top, 10)
                .padding(.bottom, 6)

                Divider()

                if analysisService.isAnalyzing {
                    AnalysisProgressView(progress: analysisService.progress)
                } else if !analysisService.segments.isEmpty {
                    TranscriptEditorView(analysisService: analysisService, onSeek: { videoModel.seek(to: $0) }, currentTime: videoModel.currentTime)
                } else {
                    Spacer()
                    Text("영상을 불러오세요")
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                // Inline error display
                if let errorMsg = analysisService.error {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(errorMsg)
                            .lineLimit(3)
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                // Bridge diagnostics (hidden in production — use --test-bridge CLI)
                if !bridgeStatus.isEmpty {
                    Text(bridgeStatus)
                        .font(.caption)
                        .foregroundStyle(bridgeStatus.contains("✅") ? .green : .secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
            }
            .frame(minWidth: 250)
        } detail: {
            // Right panel — video preview + timeline
            VStack(spacing: 0) {
                // Video player (S02)
                VideoPreviewView(model: videoModel)
                    .frame(maxHeight: .infinity)

                Divider()

                // Timeline bar (S05)
                TimelineBarView(
                    segments: analysisService.segments,
                    duration: videoModel.duration,
                    currentTime: videoModel.currentTime,
                    onSeek: { videoModel.seek(to: $0) }
                )
                .frame(height: 60)

                Divider()

                // Find & Replace bar
                if showFindReplace {
                    FindReplaceView(analysisService: analysisService, isVisible: $showFindReplace)
                    Divider()
                }

                // Toolbar
                HStack(spacing: 12) {
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audio, .mp3, .mpeg4Audio, .wav, .aiff]
                        panel.allowsMultipleSelection = false
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                videoModel.loadVideo(url: url)
                            }
                        }
                    } label: {
                        Label("열기", systemImage: "folder")
                    }

                    Button {
                        Task {
                            guard let url = videoModel.videoURL else { return }
                            await analysisService.analyze(videoURL: url)
                        }
                    } label: {
                        Label("분석", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(videoModel.videoURL == nil || analysisService.isAnalyzing)

                    Spacer()

                    Button {
                        analysisService.removeDiscardedSegments()
                    } label: {
                        Label("무음 제거", systemImage: "scissors")
                    }
                    .disabled(analysisService.segments.isEmpty)

                    Button {
                        showFindReplace.toggle()
                    } label: {
                        Label("찾기", systemImage: "magnifyingglass")
                    }
                    .disabled(analysisService.segments.isEmpty)

                    Menu {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.displayName) {
                                exportFile(format: format)
                            }
                        }
                    } label: {
                        Label("내보내기", systemImage: "square.and.arrow.up")
                    }
                    .disabled(analysisService.segments.isEmpty)
                }
                .padding(8)
            }
        }
        .background {
            // Hidden button for Cmd+F keyboard shortcut
            Button("") {
                showFindReplace.toggle()
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Export

    /// Opens NSSavePanel and writes the exported format file to disk.
    private func exportFile(format: ExportFormat) {
        let panel = NSSavePanel()

        // Map format to UTType
        switch format {
        case .srt:
            panel.allowedContentTypes = [.plainText]
        case .fcpxml:
            panel.allowedContentTypes = [.xml]
        case .itt:
            // iTT uses .itt extension — allow any file type so NSSavePanel respects the extension
            panel.allowedContentTypes = [.data]
        }

        // Default filename from video name + format extension
        let baseName: String
        if let videoURL = videoModel.videoURL {
            baseName = videoURL.deletingPathExtension().lastPathComponent
        } else {
            baseName = "export"
        }
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let content: String
            switch format {
            case .srt:
                content = ExportService.generateSRT(segments: analysisService.segments)
            case .fcpxml:
                // Use actual videoInfo if available, fall back to sensible defaults
                let info = analysisService.videoInfo ?? VideoInfo(
                    fps: 30,
                    width: 1920,
                    height: 1080,
                    duration: 0
                )
                content = ExportService.generateFCPXML(
                    segments: analysisService.segments,
                    videoInfo: info,
                    videoURL: videoModel.videoURL ?? URL(fileURLWithPath: "/unknown")
                )
            case .itt:
                content = ExportService.generateITT(segments: analysisService.segments, fps: analysisService.videoInfo?.fps ?? 24.0)
            }

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[ExportService] Failed to write \(format.fileExtension): \(error)")
            }
        }
    }

    // MARK: - Bridge test

    /// Walk up from cwd to find the directory containing `silence_cutter/`.
    private func findProjectRoot() -> String {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<5 {
            if fm.fileExists(atPath: dir.appendingPathComponent("silence_cutter").path) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return fm.currentDirectoryPath
    }

    private func testBridge() async {
        isTesting = true
        bridgeStatus = "Python 프로세스 시작 중…"

        bridge.projectRoot = findProjectRoot()

        do {
            try bridge.start()
            bridgeStatus = "ping 전송 중…"

            let result = try await bridge.call("ping", timeout: 10)
            if case .string(let value) = result, value == "pong" {
                bridgeStatus = "✅ ping → pong 왕복 성공"
            } else {
                bridgeStatus = "⚠️ 예상치 못한 응답: \(result)"
            }

            bridge.stop()
        } catch {
            bridgeStatus = "❌ 오류: \(error)"
            bridge.stop()
        }

        isTesting = false
    }
}

#Preview {
    ContentView()
}
