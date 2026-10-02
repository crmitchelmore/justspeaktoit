#if os(iOS)
import SpeakCore
import SwiftUI

// MARK: - Post-Processing Settings View

struct PostProcessingSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Model") {
                ForEach(Array(AppSettings.postProcessingModels.enumerated()), id: \.offset) { _, model in
                    Button {
                        settings.postProcessingModel = model.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName)
                                    .foregroundStyle(.primary)
                                Text(model.description ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            IOSModelCredentialStatusView(
                                availability: ModelCredentialResolver.availability(
                                    for: model.id,
                                    purpose: .postProcessing,
                                    storedAPIKeyIdentifiers: settings.storedAPIKeyIdentifiers
                                )
                            )

                            if settings.postProcessingModel == model.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
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
