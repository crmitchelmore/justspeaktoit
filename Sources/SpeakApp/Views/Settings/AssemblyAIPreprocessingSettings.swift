import AppKit
import SpeakCore
import SwiftUI

/// What replaces post-processing settings while an AssemblyAI live model is
/// active: what the integration sends, and the keyterms field it sends.
struct AssemblyAIPreprocessingSettings: View, AppSettingsBindingProviding {
  @EnvironmentObject var settings: AppSettings

  var body: some View {
    Group {
      SettingsCard(title: "Pre-processing", systemImage: "bolt.fill", tint: Color.mint) {
        VStack(alignment: .leading, spacing: 12) {
          Label(
            "Universal-3.6 Pro supports contextual prompting, but this app currently sends keyterms only."
              + " Formatting and style instructions remain in post-processing.",
            systemImage: "bolt.fill"
          )
          .font(.callout)
          .foregroundStyle(.mint)

          VStack(alignment: .leading, spacing: 6) {
            Text("Used by the AssemblyAI live integration:")
              .font(.caption.weight(.semibold))
            Label("Keyterms prompting (up to 100 terms, each up to 50 characters)", systemImage: "checkmark.circle")
            Label("Dynamic keyterm updates during a session", systemImage: "checkmark.circle")
            Label("One automatically formatted final transcript per turn", systemImage: "checkmark.circle")

            Text("Available in the API but not configured here:")
              .font(.caption.weight(.semibold))
              .padding(.top, 4)
            Label("Contextual prompt and agent context", systemImage: "info.circle")
            Text("Use transcript post-processing for formatting or behavioral instructions.")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
        }
      }
      .speakTooltip("The app sends AssemblyAI recognition keyterms; formatting prompts run after transcription.")

      SettingsCard(title: "Keyterms", systemImage: "textformat.abc", tint: Color.blue) {
        VStack(alignment: .leading, spacing: 8) {
          Text(
            "Comma-separated terms to boost recognition accuracy (e.g. proper nouns, jargon). "
              + "Max 100 terms, each ≤50 characters."
          )
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField(
            "AssemblyAI, Universal-3.6 Pro, Keanu Reeves",
            text: settingsBinding(\AppSettings.assemblyAIKeyterms)
          )
          .textFieldStyle(.roundedBorder)
        }
      }
      .speakTooltip("Add domain-specific terms to improve Universal-3.6 Pro recognition accuracy.")
    }
  }
}
