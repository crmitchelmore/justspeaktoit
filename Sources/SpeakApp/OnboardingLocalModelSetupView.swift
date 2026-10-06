import SpeakCore
import SwiftUI

struct OnboardingLocalModelSetupView: View {
    @ObservedObject var state: OnboardingState
    @ObservedObject private var localModels = LocalModelManager.shared
    @State private var downloadTask: Task<Void, Never>?

    private var presets: [LocalTranscriptionStarterPreset] {
        LocalTranscriptionStarterPreset.recommended(
            for: .batch,
            availableModels: localModels.availableModels,
            supportsParakeet: false
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download a model. No account or API key needed.")
                .font(.headline)
            Text("Audio stays on this Mac. These models transcribe after recording stops. "
                + "The first download needs internet; dictation then works offline.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(presets) { preset in
                presetRow(preset)
                Divider()
            }

            if let error = state.validationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("onboardingLocalModelError")
            }
            Text("You can change models or enable local streaming in Settings later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 40)
        .onDisappear { downloadTask?.cancel() }
    }

    private func presetRow(_ preset: LocalTranscriptionStarterPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preset.displayName)
                .font(.headline)
            Text("\(preset.recommendation) · ~\(preset.approximateSizeMB) MB")
                .font(.subheadline)
            Text(preset.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if preset.id == .phononBatch {
                Text("English only. Requires Apple silicon and an additional runtime download. "
                    + "Loading the model adds seconds to each recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Link(
                        "Model & attribution",
                        destination: URL(string: "https://huggingface.co/FermionResearch/Phonon-2")!
                    )
                    Link("CC-BY-4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }
                .font(.caption)
            }
            HStack {
                if state.isConfiguringLocalModel {
                    ProgressView().controlSize(.small)
                    Text("Downloading and preparing...")
                        .font(.caption)
                }
                Spacer()
                Button(actionTitle(for: preset)) {
                    downloadTask = Task {
                        await state.configureLocalModel(preset) {
                            switch preset.engine {
                            case .whisperKit(let model), .phonon(let model):
                                if !localModels.isInstalled(model.id) {
                                    await localModels.install(model)
                                }
                                return localModels.installState(for: model.id)
                            case .parakeet:
                                return .failed("Choose a batch model for onboarding")
                            }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(state.isConfiguringLocalModel || state.configuredLocalPreset == preset)
                .accessibilityIdentifier("onboardingLocalModel-\(preset.id.rawValue)")
            }
        }
    }

    private func actionTitle(for preset: LocalTranscriptionStarterPreset) -> String {
        if state.configuredLocalPreset == preset { return "Configured and ready" }
        switch preset.engine {
        case .whisperKit(let model), .phonon(let model):
            return localModels.isInstalled(model.id) ? "Use This Model" : "Configure and Download"
        case .parakeet:
            return "Configure and Download"
        }
    }
}
