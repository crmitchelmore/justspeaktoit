#if os(iOS)
import SpeakCore
import SwiftUI

@available(iOS 26.0, *)
struct AppleSpeechPreparationView: View {
    let modelID: String
    let localeIdentifier: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var preparationTask: Task<Void, Never>?
    @ObservedObject private var preparation = AppleSpeechModelPreparation.shared

    private var configuration: AppleSpeechModelPreparation.Configuration {
        .init(modelID: modelID, localeIdentifier: localeIdentifier)
    }

    private var state: AppleSpeechModelPreparation.State {
        preparation.selection == configuration ? preparation.state : .idle
    }

    private var isPreparing: Bool {
        state == .checking || state == .preparing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Prepare Apple model") {
                let selected = configuration
                preparationTask = Task { await preparation.prepare(selected) }
            }
            .disabled(isPreparing || scenePhase != .active)
            .frame(minHeight: 44)
            .accessibilityIdentifier("prepareAppleModelButton")

            if isPreparing { ProgressView() }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("appleModelPreparationStatus")
        }
        .onAppear { preparation.select(configuration) }
        .onChange(of: configuration) { _, selected in
            preparationTask?.cancel()
            preparation.select(selected)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelPreparation() }
        }
        .onDisappear { cancelPreparation() }
    }

    private func cancelPreparation() {
        preparationTask?.cancel()
        preparationTask = nil
        preparation.cancel()
    }

    private var statusText: String {
        switch state {
        case .idle:
            return "Prepare the selected model and language before recording. "
                + "This may download Apple speech assets. Keep Settings open until it finishes."
        case .checking:
            return "Checking Apple model availability…"
        case .preparing:
            return "Preparing Apple speech assets… Keep Settings open."
        case .ready(let resolved):
            let name = ModelCatalog.friendlyName(for: resolved.modelID)
            return "\(name) is ready for \(resolved.localeIdentifier). Availability is checked again when recording."
        case .failed(let message):
            return "Preparation failed: \(message) Tap Prepare Apple model to retry."
        }
    }
}
#endif
