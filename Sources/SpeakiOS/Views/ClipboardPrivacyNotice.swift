#if os(iOS)
import SwiftUI

struct ClipboardPrivacyNotice: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Clipboard privacy updated", systemImage: "hand.raised.fill")
                .font(.headline)

            Text(self.settings.transcriptClipboardPrivacySummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Change this anytime in Settings → Privacy Information → Clipboard.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                NavigationLink("Clipboard Settings") {
                    PrivacyView()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("clipboardPrivacySettingsButton")

                Button("Got it") {
                    self.settings.acknowledgeTranscriptClipboardNotice()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("clipboardPrivacyAcknowledgeButton")
            }
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("clipboardPrivacyNotice")
    }
}
#endif
