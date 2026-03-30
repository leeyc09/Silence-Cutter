import SwiftUI

/// Pre-analysis settings dialog — shown when a video is loaded or "분석" is clicked.
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
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Settings content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Language & Model
                    VStack(alignment: .leading, spacing: 10) {
                        Label("음성 인식", systemImage: "waveform")
                            .font(.subheadline.bold())
                            .foregroundStyle(.cyan)

                        HStack {
                            Text("언어")
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
                            Text("모델")
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
                        Label("무음 감지", systemImage: "speaker.wave.2")
                            .font(.subheadline.bold())
                            .foregroundStyle(.cyan)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("감도")
                                    .frame(width: 70, alignment: .leading)
                                Slider(value: $settings.vadThreshold, in: 0.1...0.9, step: 0.05)
                                Text(String(format: "%.2f", settings.vadThreshold))
                                    .font(.caption.monospaced())
                                    .frame(width: 36)
                            }
                            Text("낮을수록 민감 (작은 소리도 음성으로 인식)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 74)
                        }

                        HStack {
                            Text("최소 무음")
                                .frame(width: 70, alignment: .leading)
                            TextField("", value: $settings.minSilenceMs, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("패딩")
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
                        Label("자막", systemImage: "captions.bubble")
                            .font(.subheadline.bold())
                            .foregroundStyle(.cyan)

                        HStack {
                            Text("클립 최대")
                                .frame(width: 70, alignment: .leading)
                            Slider(value: $settings.maxSegmentSeconds, in: 3...20, step: 1)
                            Text("\(Int(settings.maxSegmentSeconds))초")
                                .font(.caption.monospaced())
                                .frame(width: 30)
                        }

                        HStack {
                            Text("줄 최대")
                                .frame(width: 70, alignment: .leading)
                            TextField("", value: $settings.maxSubtitleChars, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("글자")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("폰트")
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
                Button("기본값") {
                    settings.resetToDefaults()
                }
                .foregroundStyle(.secondary)

                Spacer()

                Button("취소") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Button("분석 시작") {
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
