import SwiftUI
import UniformTypeIdentifiers

/// Sheet for retranscribing an edited FCPXML — settings + progress + completion.
struct RetranscribeSheetView: View {
    let inputURL: URL
    let defaultOutputURL: URL
    let settings: AnalysisSettings
    @Binding var state: ContentView.RetranscribeState
    let analysisService: AnalysisService
    var pythonEnv: PythonEnvironment
    let onDismiss: () -> Void

    // Local settings for this retranscribe run
    @State private var language: String = "Korean"
    @State private var asrModel: AnalysisSettings.ASRModel = .small
    @State private var exportITT: Bool = true
    @State private var outputURL: URL?
    @State private var outputInitialized = false
    @State private var retranscribeTask: Task<Void, Never>?

    // Timer for progress polling
    @State private var progressDetail: String = ""
    @State private var progressTimer: Timer?

    /// The output URL to use — local override or the default passed from parent.
    private var effectiveOutputURL: URL {
        outputURL ?? defaultOutputURL
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("자막 재생성")
                    .font(.headline)
                Spacer()
                if case .running = state {
                    // No close button while running
                } else {
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()

            Divider()

            switch state {
            case .idle:
                settingsContent
            case .running:
                progressContent
            case .done(let path):
                doneContent(path: path)
            case .error(let msg):
                errorContent(message: msg)
            }
        }
        .frame(width: 420)
        .onAppear {
            language = settings.language
            asrModel = settings.asrModel
            if !outputInitialized {
                outputURL = defaultOutputURL
                outputInitialized = true
            }
        }
        .onDisappear {
            progressTimer?.invalidate()
        }
    }

    // MARK: - Settings (before start)

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Input file
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.cyan)
                Text("입력")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Text(inputURL.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal)

            // Output path
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(.cyan)
                Text("저장")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Text(effectiveOutputURL.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("변경") {
                    chooseOutputPath()
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)

            Divider()
                .padding(.horizontal)

            // Language picker
            VStack(alignment: .leading, spacing: 4) {
                Text("언어")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Picker("", selection: $language) {
                    ForEach(AnalysisSettings.languages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)

            // ASR model picker
            VStack(alignment: .leading, spacing: 4) {
                Text("AI 모델")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Picker("", selection: $asrModel) {
                    ForEach(AnalysisSettings.ASRModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)

            // iTT export toggle
            Toggle("iTT 캡션도 함께 생성", isOn: $exportITT)
                .padding(.horizontal)

            // Start button
            HStack {
                Spacer()
                Button("자막 재생성 시작") {
                    startRetranscribe()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                Spacer()
            }
            .padding()
        }
        .padding(.top, 12)
    }

    // MARK: - Progress (while running)

    private var progressContent: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(1.3)

            Text("자막 재생성 중…")
                .font(.headline)

            Text(progressDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 40)

            Button(role: .destructive) {
                cancelRetranscribe()
            } label: {
                Label("취소", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
        .frame(minHeight: 200)
        .onAppear { startProgressPolling() }
        .onDisappear { progressTimer?.invalidate() }
    }

    // MARK: - Done

    private func doneContent(path: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("완료!")
                .font(.headline)

            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Finder에서 보기") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                Button("닫기") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
        .frame(minHeight: 200)
    }

    // MARK: - Error

    private func errorContent(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("오류 발생")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("다시 시도") {
                    state = .idle
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                Button("닫기") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
        .frame(minHeight: 200)
    }

    // MARK: - Actions

    private func chooseOutputPath() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "fcpxml")!]
        if let existing = outputURL {
            savePanel.directoryURL = existing.deletingLastPathComponent()
            savePanel.nameFieldStringValue = existing.lastPathComponent
        }

        savePanel.beginSheetModal(for: window) { response in
            if response == .OK, let url = savePanel.url {
                outputURL = url
            }
        }
    }

    private func startRetranscribe() {
        let outURL = effectiveOutputURL

        state = .running
        progressDetail = ""

        retranscribeTask = Task {
            do {
                let result = try await analysisService.retranscribeToFile(
                    fcpxmlURL: inputURL,
                    outputURL: outURL,
                    environment: pythonEnv,
                    language: language,
                    asrModel: asrModel.rawValue,
                    fontSize: settings.fontSizeExport,
                    maxSubtitleChars: settings.maxSubtitleChars,
                    exportITT: exportITT
                )
                await MainActor.run {
                    state = .done(outputPath: result.outputPath)
                }
            } catch {
                if Task.isCancelled {
                    await MainActor.run { state = .idle }
                } else {
                    await MainActor.run {
                        state = .error(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func cancelRetranscribe() {
        retranscribeTask?.cancel()
        analysisService.cancelRetranscribe()
        state = .idle
    }

    private func startProgressPolling() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                if let p = analysisService.retranscribeProgress {
                    progressDetail = p.detail
                }
            }
        }
    }
}
