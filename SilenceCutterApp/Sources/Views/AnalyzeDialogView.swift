import SwiftUI

/// Pre-analysis settings dialog — shown when a video is loaded or "Analyze" is clicked.
/// Lets the user configure language, model, VAD sensitivity, etc. before starting analysis.
struct AnalyzeDialogView: View {
    @Bindable var settings: AnalysisSettings
    @Binding var isPresented: Bool
    var onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundStyle(.cyan)
                    .font(.title2)
                Text(L10n.tr("dialog.title"))
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
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Settings content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Language & Model
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L10n.tr("dialog.speech_recognition"), systemImage: "waveform")
                            .font(.subheadline.bold())
                            .foregroundStyle(.cyan)

                        HStack {
                            Text(L10n.tr("dialog.language"))
                                .frame(width: 70, alignment: .leading)
                            Picker("", selection: $settings.language) {
                                ForEach(AnalysisSettings.languages, id: \.self) { lang in
                                    Text(lang).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }

                        HStack {
                            Text(L10n.tr("dialog.model"))
                                .frame(width: 70, alignment: .leading)
                            Picker("", selection: $settings.asrModel) {
                                ForEach(AnalysisSettings.ASRModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Divider()

                    // VAD
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L10n.tr("dialog.silence_detection"), systemImage: "speaker.wave.2")
                            .font(.subheadline.bold())
                            .foregroundStyle(.cyan)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(L10n.tr("dialog.sensitivity"))
                                    .frame(width: 70, alignment: .leading)
                                Slider(value: $settings.vadThreshold, in: 0.1...0.9, step: 0.05)
                                Text(String(format: "%.2f", settings.vadThreshold))
                                    .font(.caption.monospaced())
                                    .frame(width: 36)
                            }
                            Text(L10n.tr("dialog.sensitivity_hint"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 74)
                        }

                        HStack {
                            Text(L10n.tr("dialog.min_silence"))
                                .frame(width: 70, alignment: .leading)
                            TextField("", value: $settings.minSilenceMs, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(L10n.tr("dialog.padding"))
                                .frame(width: 40, alignment: .leading)
                            TextField("", value: $settings.speechPadMs, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // Segment & Subtitle
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L10n.tr("dialog.subtitle"), systemImage: "captions.bubble")
                            .font(.subheadline.bold())
                            .foregroundStyle(.cyan)

                        HStack {
                            Text(L10n.tr("dialog.max_clip"))
                                .frame(width: 70, alignment: .leading)
                            Slider(value: $settings.maxSegmentSeconds, in: 3...20, step: 1)
                            Text(L10n.tr("dialog.seconds_unit", Int(settings.maxSegmentSeconds)))
                                .font(.caption.monospaced())
                                .frame(width: 30)
                        }

                        HStack {
                            Text(L10n.tr("dialog.max_chars"))
                                .frame(width: 70, alignment: .leading)
                            TextField("", value: $settings.maxSubtitleChars, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text(L10n.tr("dialog.chars_unit"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(L10n.tr("dialog.font"))
                                .frame(width: 40, alignment: .leading)
                            TextField("", value: $settings.fontSizeExport, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("pt")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Action buttons
            HStack {
                Button(L10n.tr("dialog.defaults")) {
                    settings.resetToDefaults()
                }
                .foregroundStyle(.secondary)

                Spacer()

                Button(L10n.tr("dialog.cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Button(L10n.tr("dialog.start")) {
                    isPresented = false
                    onStart()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .keyboardShortcut(.return)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 440, height: 520)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    AnalyzeDialogView(
        settings: AnalysisSettings(),
        isPresented: .constant(true),
        onStart: {}
    )
    .preferredColorScheme(.dark)
}
