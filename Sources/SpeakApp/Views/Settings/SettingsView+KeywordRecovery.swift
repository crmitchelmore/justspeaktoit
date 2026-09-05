import SwiftUI

extension SettingsView {
  var transcriptionKeywordRecoveryCard: some View {
    SettingsCard(title: "Saved keyword edits", systemImage: "arrow.uturn.backward", tint: Color.blue) {
      VStack(alignment: .leading, spacing: 12) {
        Text("A keyword clear conflicted with another saved edit. The other words were kept here for review.")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(settings.recoveredTranscriptionKeywords, id: \.self) { recovered in
          VStack(alignment: .leading, spacing: 8) {
            Text(recovered)
              .textSelection(.enabled)
            HStack {
              Button("Restore keywords") {
                settings.restoreTranscriptionKeywords(recovered)
              }
              Button("Discard saved edit", role: .destructive) {
                settings.discardRecoveredTranscriptionKeywords(recovered)
              }
            }
          }
        }
      }
    }
  }
}
