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
    @State private var retranscribeItem: RetranscribeItem?
    @State private var retranscribeState: RetranscribeState = .idle

    struct RetranscribeItem: Identifiable {
        let id = UUID()
        let inputURL: URL
        let defaultOutputURL: URL
    }

    enum RetranscribeState {
        case idle
        case running
        case done(outputPath: String)
        case error(String)
    }

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
        .sheet(item: $retranscribeItem) { item in
            RetranscribeSheetView(
                inputURL: item.inputURL,
                defaultOutputURL: item.defaultOutputURL,
                settings: settings,
                state: $retranscribeState,
                analysisService: analysisService,
                pythonEnv: pythonEnv,
                onDismiss: { retranscribeItem = nil }
            )
        }
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
                    TranscriptEditorView(analysisService: analysisService, onSeek: { videoModel.seek(to: $0) }, videoModel: videoModel)
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

                TimelineBarWrapper(
                    segments: analysisService.segments,
                    videoModel: videoModel,
                    timelineDuration: analysisService.timelineDuration,
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

                    Button {
                        importFCPXML()
                    } label: {
                        Label(L10n.tr("toolbar.import_fcpxml"), systemImage: "doc.badge.arrow.up")
                    }
                    .disabled(analysisService.isAnalyzing)

                    Spacer()

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

    // MARK: - Import FCPXML (Retranscribe to file)

    /// Opens an NSOpenPanel for .fcpxml files, then shows the retranscribe settings sheet.
    private func importFCPXML() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true   // .fcpxmld is a directory bundle
        openPanel.canChooseFiles = true
        openPanel.treatsFilePackagesAsDirectories = false
        openPanel.message = L10n.tr("toolbar.import_fcpxml_message")

        let response = openPanel.runModal()
        guard response == .OK, let url = openPanel.url else { return }

        let ext = url.pathExtension.lowercased()
        guard ext == "fcpxmld" || ext == "fcpxml" || ext == "xml" else {
            print("[Silenci] Unsupported file: \(url.lastPathComponent)")
            return
        }

        // Resolve .fcpxmld bundle → Info.fcpxml inside
        let resolvedURL: URL
        if ext == "fcpxmld" {
            resolvedURL = url.appendingPathComponent("Info.fcpxml")
            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                print("[Silenci] Error: Info.fcpxml not found inside .fcpxmld bundle")
                return
            }
        } else {
            resolvedURL = url
        }

        retranscribeState = .idle
        let dir = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let outURL = dir.appendingPathComponent(baseName + "_resub.fcpxml")
        retranscribeItem = RetranscribeItem(inputURL: resolvedURL, defaultOutputURL: outURL)
    }

    /// Parse FCPXML to find the source video file path.
    private static func findVideoInFCPXML(_ fcpxmlURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: fcpxmlURL),
              let xmlString = String(data: data, encoding: .utf8) else { return nil }

        // Find file:// URL in media-rep src attribute
        if let range = xmlString.range(of: #"file://[^"]*\.(mov|mp4|m4v|avi|mkv|MOV|MP4)"#, options: .regularExpression) {
            let urlString = String(xmlString[range])
            // URL decode percent-encoded paths (e.g. Korean filenames)
            if let decoded = urlString.removingPercentEncoding,
               let url = URL(string: decoded.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString) {
                let path = decoded.replacingOccurrences(of: "file://", with: "")
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
            // Fallback: try direct URL construction
            if let url = URL(string: urlString), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    // MARK: - Export

    private func exportFile(format: ExportFormat) {
        let panel = NSSavePanel()

        switch format {
        case .srt:
            panel.allowedContentTypes = []
        case .fcpxml:
            panel.allowedContentTypes = []
        case .itt:
            panel.allowedContentTypes = []
        }

        let baseName: String
        if let videoURL = videoModel.videoURL {
            baseName = videoURL.deletingPathExtension().lastPathComponent
        } else {
            baseName = "export"
        }
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        panel.allowsOtherFileTypes = true

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
