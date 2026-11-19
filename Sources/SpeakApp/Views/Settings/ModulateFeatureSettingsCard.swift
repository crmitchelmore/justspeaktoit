import SpeakCore
import SwiftUI

/// Modulate's optional diarisation and signal-detection flags, shown under
/// Transcription when a Modulate model is selected.
struct ModulateFeatureSettingsCard: View, AppSettingsBindingProviding {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let usesEnglishFastBatch = settings.batchTranscriptionModel == "modulate/velma-2-stt-batch-english-vfast"

        return SettingsCard(
            title: "Modulate features",
            systemImage: "slider.horizontal.3",
            tint: Color.teal
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "These options apply to Modulate streaming and the multilingual batch model."
                        + " Speaker diarisation is on by default."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle(
                    "Speaker diarisation",
                    isOn: settingsBinding(\AppSettings.modulateSpeakerDiarizationEnabled)
                )
                .speakTooltip("Label different speakers in Modulate transcripts when the provider supports it.")

                Toggle(
                    "Emotion detection",
                    isOn: settingsBinding(\AppSettings.modulateEmotionSignalEnabled)
                )
                .speakTooltip("Ask Modulate to attach an emotion label to each detected utterance.")

                Toggle(
                    "Accent detection",
                    isOn: settingsBinding(\AppSettings.modulateAccentSignalEnabled)
                )
                .speakTooltip("Ask Modulate to identify the speaker accent for each utterance.")

                Toggle(
                    "PII/PHI tagging",
                    isOn: settingsBinding(\AppSettings.modulatePIIPhiTaggingEnabled)
                )
                .speakTooltip("Wrap sensitive personal or health information in Modulate's tagging output.")

                if usesEnglishFastBatch {
                    Text(
                        "The Modulate English Fast batch model ignores these optional flags."
                            + " They still apply to Modulate streaming and the multilingual batch model."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .speakTooltip("Configure Modulate's diarisation and signal-detection features.")
    }
}
