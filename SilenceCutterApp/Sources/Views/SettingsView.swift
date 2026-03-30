import SwiftUI

/// Settings panel — collapsible section in the sidebar or a sheet.
struct SettingsView: View {
    @Bindable var settings: AnalysisSettings
    @Binding var isPresented: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                languageSection
                Divider()
                vadSection
                Divider()
                segmentSection
                Divider()
                subtitleSection
                Divider()
                resetSection
            }
            .padding(20)
        }
        .frame(width: 380, height: 520)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "gearshape.fill")
                .foregroundStyle(.cyan)
            Text("분석 설정")
                .font(.title3.bold())
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Language & Model

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("음성 인식", systemImage: "waveform")
                .font(.headline)
                .foregroundStyle(.cyan)

            HStack {
                Text("언어")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $settings.language) {
                    ForEach(AnalysisSettings.languages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            HStack {
                Text("ASR 모델")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $settings.asrModel) {
                    ForEach(AnalysisSettings.ASRModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - VAD Settings

    private var vadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("무음 감지 (VAD)", systemImage: "speaker.wave.2")
                .font(.headline)
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("감도")
                        .frame(width: 80, alignment: .leading)
                    Slider(value: $settings.vadThreshold, in: 0.1...0.9, step: 0.05)
                    Text(String(format: "%.2f", settings.vadThreshold))
                        .font(.caption.monospaced())
                        .frame(width: 40)
                }
                Text("낮을수록 민감 (작은 소리도 음성으로 인식)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text("최소 무음")
                    .frame(width: 80, alignment: .leading)
                TextField("", value: $settings.minSilenceMs, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Text("최소 음성")
                    .frame(width: 80, alignment: .leading)
                TextField("", value: $settings.minSpeechMs, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Text("패딩")
                    .frame(width: 80, alignment: .leading)
                TextField("", value: $settings.speechPadMs, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Segment Settings

    private var segmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("세그먼트 분할", systemImage: "scissors")
                .font(.headline)
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("최대 길이")
                        .frame(width: 80, alignment: .leading)
                    Slider(value: $settings.maxSegmentSeconds, in: 3...20, step: 1)
                    Text("\(Int(settings.maxSegmentSeconds))초")
                        .font(.caption.monospaced())
                        .frame(width: 35)
                }
                Text("클립 하나의 최대 길이 (단어 경계에서 분할)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Subtitle Settings

    private var subtitleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("자막", systemImage: "captions.bubble")
                .font(.headline)
                .foregroundStyle(.cyan)

            HStack {
                Text("줄 최대")
                    .frame(width: 80, alignment: .leading)
                TextField("", value: $settings.maxSubtitleChars, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("글자")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Text("폰트 크기")
                    .frame(width: 80, alignment: .leading)
                TextField("", value: $settings.fontSizeExport, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("pt (FCPXML)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        HStack {
            Spacer()
            Button("기본값으로 초기화") {
                settings.resetToDefaults()
            }
            .foregroundStyle(.red)
        }
    }
}

#Preview {
    SettingsView(
        settings: AnalysisSettings(),
        isPresented: .constant(true)
    )
    .preferredColorScheme(.dark)
}
