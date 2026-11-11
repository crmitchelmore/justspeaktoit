#if os(iOS)
import SpeakCore
import SwiftUI

// MARK: - Post-Processing Settings View

struct PostProcessingSettingsView: View {
    @ObservedObject var settings: AppSettings

    private var modelOptions: [ModelCatalog.Option] {
        var options = AppSettings.postProcessingModels
        if !options.contains(where: { $0.id == settings.postProcessingModel }),
           let retained = CleanupModelSelection.retainedOption(settings.postProcessingModel) {
            options.append(retained)
        }
        return options
    }

    var body: some View {
        Form {
            Section("Model discovery") {
                CleanupModelDiscoveryView(selection: $settings.postProcessingModel,
                                          enabled: $settings.cleanupModelDiscoveryEnabled)
            }
            Section("Model") {
                ForEach(Array(modelOptions.enumerated()), id: \.offset) { _, model in
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

                            ModelCredentialStatusView(
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
