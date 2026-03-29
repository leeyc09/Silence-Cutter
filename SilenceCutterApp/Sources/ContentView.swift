import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var bridge = PythonBridge()
    @State private var videoModel = VideoPlayerModel()
    @State private var analysisService = AnalysisService()
    @State private var bridgeStatus: String = ""
    @State private var isTesting = false

    var body: some View {
        NavigationSplitView {
            // Left panel — transcript / analysis
            VStack(spacing: 0) {
                Text("Transcript")
                    .font(.headline)
                    .padding(.top)
                    .padding(.bottom, 8)

                Divider()

                if analysisService.isAnalyzing {
                    AnalysisProgressView(progress: analysisService.progress)
                } else if !analysisService.segments.isEmpty {
                    TranscriptEditorView(analysisService: analysisService, onSeek: { videoModel.seek(to: $0) })
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

                // Bridge diagnostics
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
                VideoPlayerView(model: videoModel)
                    .frame(maxHeight: .infinity)

                Divider()

                // Timeline bar placeholder (S05)
                ZStack {
                    Rectangle()
                        .fill(Color(.windowBackgroundColor))
                    Text("Timeline")
                        .foregroundStyle(.secondary)
                }
                .frame(height: 60)

                Divider()

                // Toolbar
                HStack {
                    Button("파일 열기") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
                        panel.allowsMultipleSelection = false
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                videoModel.loadVideo(url: url)
                            }
                        }
                    }
                    Spacer()

                    Button("Bridge 테스트") {
                        Task { await testBridge() }
                    }
                    .disabled(isTesting)

                    Spacer()
                    Button("분석 시작") {
                        Task {
                            guard let url = videoModel.videoURL else { return }
                            await analysisService.analyze(videoURL: url)
                        }
                    }
                    .disabled(videoModel.videoURL == nil || analysisService.isAnalyzing)
                    Spacer()
                    Menu("내보내기") {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.displayName) {
                                // Export (S06)
                            }
                        }
                    }
                    .disabled(true)
                }
                .padding(8)
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
