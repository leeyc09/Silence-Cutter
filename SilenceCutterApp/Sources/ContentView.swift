import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    var pythonEnv: PythonEnvironment
    @State private var bridge = PythonBridge()
    @State private var videoModel = VideoPlayerModel()
    @State private var analysisService = AnalysisService()
    @State private var settings = AnalysisSettings()
    @State private var bridgeStatus: String = ""
    @State private var isTesting = false
    @State private var showFindReplace = false
    @State private var showSettings = false
    @State private var showAnalyzeDialog = false

    var body: some View {
        ZStack {
            mainContent
                .disabled(!pythonEnv.state.isReady)
                .opacity(pythonEnv.state.isReady ? 1 : 0.3)

            if !pythonEnv.state.isReady {
                setupOverlay
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Setup Overlay

    @ViewBuilder
    private var setupOverlay: some View {
        VStack(spacing: 20) {
            switch pythonEnv.state {
            case .notStarted, .checking:
                ProgressView()
                    .scaleEffect(1.5)
                Text(L10n.tr("setup.checking"))
                    .font(.headline)

            case .installing(let detail):
                VStack(spacing: 12) {
                    Text(L10n.tr("setup.installing_title"))
                        .font(.title2.bold())
                    Text(L10n.tr("setup.installing_subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ProgressView(value: pythonEnv.progress)
                        .frame(width: 300)

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text(L10n.tr("setup.failed_title"))
                        .font(.title2.bold())
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)

                    Button(L10n.tr("setup.retry")) {
                        Task { await pythonEnv.retry() }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .ready:
                EmptyView()
            }
        }
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Main Content

    private var mainContent: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "text.quote")
                        .foregroundStyle(.cyan)
                    Text(L10n.tr("main.transcript"))
                        .font(.headline)
                }
                .padding(.top, 10)
                .padding(.bottom, 6)

                Divider()

                if analysisService.isAnalyzing {
                    AnalysisProgressView(progress: analysisService.progress, onCancel: {
                        analysisService.cancelAnalysis()
                    })
                } else if !analysisService.segments.isEmpty {
                    TranscriptEditorView(analysisService: analysisService, onSeek: { videoModel.seek(to: $0) }, currentTime: videoModel.currentTime)
                } else {
                    Spacer()
                    Text(L10n.tr("main.load_video"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

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
            VStack(spacing: 0) {
                VideoPreviewView(model: videoModel)
                    .frame(maxHeight: .infinity)

                Divider()

                TimelineBarView(
                    segments: analysisService.segments,
                    duration: videoModel.duration,
                    currentTime: videoModel.currentTime,
                    onSeek: { videoModel.seek(to: $0) }
                )
                .frame(height: 60)

                Divider()

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
                                showAnalyzeDialog = true
                            }
                        }
                    } label: {
                        Label(L10n.tr("toolbar.open"), systemImage: "folder")
                    }

                    Button {
                        showAnalyzeDialog = true
                    } label: {
                        Label(L10n.tr("toolbar.analyze"), systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(videoModel.videoURL == nil || analysisService.isAnalyzing)

                    Spacer()

                    Button {
                        analysisService.removeDiscardedSegments()
                    } label: {
                        Label(L10n.tr("toolbar.remove_silence"), systemImage: "scissors")
                    }
                    .disabled(analysisService.segments.isEmpty)

                    Button {
                        showFindReplace.toggle()
                    } label: {
                        Label(L10n.tr("toolbar.find"), systemImage: "magnifyingglass")
                    }
                    .disabled(analysisService.segments.isEmpty)

                    Menu {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.displayName) {
                                exportFile(format: format)
                            }
                        }
                    } label: {
                        Label(L10n.tr("toolbar.export"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(analysisService.segments.isEmpty)

                    Button {
                        showSettings.toggle()
                    } label: {
                        Label(L10n.tr("toolbar.settings"), systemImage: "gearshape")
                    }
                }
                .padding(8)
            }
        }
        .background {
            Button("") {
                showFindReplace.toggle()
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, isPresented: $showSettings)
        }
        .sheet(isPresented: $showAnalyzeDialog) {
            AnalyzeDialogView(settings: settings, isPresented: $showAnalyzeDialog) {
                guard let url = videoModel.videoURL else { return }
                settings.save()
                analysisService.startAnalysis(videoURL: url, environment: pythonEnv, settings: settings)
            }
        }
        .onAppear {
            settings.load()
        }
    }

    // MARK: - Export

    private func exportFile(format: ExportFormat) {
        let panel = NSSavePanel()

        switch format {
        case .srt:
            panel.allowedContentTypes = [.plainText]
        case .fcpxml:
            panel.allowedContentTypes = [.xml]
        case .itt:
            panel.allowedContentTypes = [.data]
        }

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
                content = ExportService.generateSRT(segments: analysisService.segments, maxSubtitleChars: settings.maxSubtitleChars)
            case .fcpxml:
                let info = analysisService.videoInfo ?? VideoInfo(
                    fps: 30,
                    width: 1920,
                    height: 1080,
                    duration: 0
                )
                content = ExportService.generateFCPXML(
                    segments: analysisService.segments,
                    videoInfo: info,
                    videoURL: videoModel.videoURL ?? URL(fileURLWithPath: "/unknown"),
                    fontSize: settings.fontSizeExport,
                    maxSubtitleChars: settings.maxSubtitleChars
                )
            case .itt:
                content = ExportService.generateITT(segments: analysisService.segments, fps: analysisService.videoInfo?.fps ?? 24.0, maxSubtitleChars: settings.maxSubtitleChars)
            }

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[ExportService] Failed to write \(format.fileExtension): \(error)")
            }
        }
    }

    // MARK: - Bridge test

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
        bridgeStatus = "Starting Python process…"

        bridge.projectRoot = findProjectRoot()

        do {
            try bridge.start()
            bridgeStatus = "Sending ping…"

            let result = try await bridge.call("ping", timeout: 10)
            if case .string(let value) = result, value == "pong" {
                bridgeStatus = "✅ ping → pong round-trip OK"
            } else {
                bridgeStatus = "⚠️ Unexpected response: \(result)"
            }

            bridge.stop()
        } catch {
            bridgeStatus = "❌ Error: \(error)"
            bridge.stop()
        }

        isTesting = false
    }
}

#Preview {
    ContentView(pythonEnv: PythonEnvironment())
}
