#if os(iOS)
import SpeakCore
import SwiftUI

// MARK: - Post-Processing Settings View

struct PostProcessingSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                PostProcessingModelPickerRows(settings: settings)
            } header: {
                Text("Model")
            } footer: {
                Text("Native models use that provider's own key. OpenRouter offers many more models with one key.")
            }

            if !IOSLocalCleanupModelManager.shared.models.isEmpty {
                SearchableSettingsSection("On-Device Cleanup Models") {
                    IOSDownloadedCleanupModelsList(settings: settings)
                }
            }

            Section("Effective Policy Preview") {
                Text(TranscriptCleanupPolicy.systemPrompt())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Post-Processing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
