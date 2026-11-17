#if os(iOS)
import SpeakCore
import SwiftUI

/// Rows of Settings › Post-Processing › Model & Prompt › On-Device Cleanup
/// Models: each pinned llama.cpp cleanup model this device is offered, with
/// its size, state and actions, laid out like the downloaded Whisper models.
struct IOSDownloadedCleanupModelsList: View {
    @ObservedObject private var manager = IOSLocalCleanupModelManager.shared
    @ObservedObject var settings: AppSettings
    @State private var errorMessage: String?

    var body: some View {
        if !manager.engineAvailable {
            Label("On-device cleanup isn't available in this build.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("downloadedCleanupModelsUnavailable")
        }

        ForEach(manager.models, id: \.catalogueID) { model in
            IOSDownloadedModelRow(
                model: Self.rowModel(model),
                state: manager.state(for: model),
                sizeBytes: manager.installedSizeBytes(model),
                isRecommended: true,
                isSelected: settings.postProcessingModel == model.catalogueID,
                isImported: false,
                actions: IOSDownloadedModelRow.Actions(
                    download: { manager.download(model) },
                    cancel: { manager.cancelDownload(model) },
                    use: { settings.postProcessingModel = model.catalogueID },
                    remove: { remove(model) }
                )
            )
        }

        if let model = IOSLocalCleanupModels.model(for: settings.postProcessingModel),
           manager.state(for: model) != .installed {
            Label(
                "Download \(model.displayName) before polishing; until then the original transcript is kept.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .font(.caption)
            .accessibilityIdentifier("downloadedCleanupModelMissingWarning")
        }

        SettingsFootnote(
            "Cleans transcripts on \(DeviceCopy.thisDevice) with your prompt, with no API key and nothing "
                + "uploaded. Each model is checked against its pinned size and SHA-256 before use. "
                + "If cleanup fails, the original transcript is kept and the reason is shown."
        )
        .onAppear { manager.refresh() }
        .alert(
            "On-Device Cleanup Models",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(errorMessage ?? "") }
        )
    }

    static func rowModel(_ model: LlamaCppModel) -> IOSDownloadedModelRow.Model {
        IOSDownloadedModelRow.Model(
            id: model.catalogueID,
            displayName: model.displayName,
            approximateSizeMB: Int(model.artifact.byteCount / 1_000_000)
        )
    }

    private func remove(_ model: LlamaCppModel) {
        do {
            try manager.remove(model)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
