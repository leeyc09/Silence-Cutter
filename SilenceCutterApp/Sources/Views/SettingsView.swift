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
            Text(L10n.tr("settings.title"))
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
            Label(L10n.tr("settings.speech_recognition"), systemImage: "waveform")
                .font(.headline)
                .foregroundStyle(.cyan)

            HStack {
                Text(L10n.tr("settings.language"))
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
                Text(L10n.tr("settings.asr_model"))
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
            Label(L10n.tr("settings.vad"), systemImage: "speaker.wave.2")
                .font(.headline)
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.tr("settings.sensitivity"))
                        .frame(width: 80, alignment: .leading)
                    Slider(value: $settings.vadThreshold, in: 0.1...0.9, step: 0.05)
                    Text(String(format: "%.2f", settings.vadThreshold))
                        .font(.caption.monospaced())
                        .frame(width: 40)
                }
                Text(L10n.tr("settings.sensitivity_hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(L10n.tr("settings.min_silence"))
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
                Text(L10n.tr("settings.min_speech"))
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
                Text(L10n.tr("settings.padding"))
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
            Label(L10n.tr("settings.segment"), systemImage: "scissors")
                .font(.headline)
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.tr("settings.max_length"))
                        .frame(width: 80, alignment: .leading)
                    Slider(value: $settings.maxSegmentSeconds, in: 3...20, step: 1)
                    Text(L10n.tr("settings.seconds_unit", Int(settings.maxSegmentSeconds)))
                        .font(.caption.monospaced())
                        .frame(width: 35)
                }
                Text(L10n.tr("settings.max_length_hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Subtitle Settings

    private var subtitleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("settings.subtitle"), systemImage: "captions.bubble")
                .font(.headline)
                .foregroundStyle(.cyan)

            HStack {
                Text(L10n.tr("settings.max_chars"))
                    .frame(width: 80, alignment: .leading)
                TextField("", value: $settings.maxSubtitleChars, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text(L10n.tr("settings.chars_unit"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Text(L10n.tr("settings.font_size"))
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
            Button(L10n.tr("settings.reset")) {
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
