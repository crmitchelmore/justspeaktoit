import Foundation
import SpeakCore
import SpeakDesktop

struct DesktopComparisonModelState {
    let option: ModelCatalog.Option
    let key: String
    let unavailableReason: String?
}

extension DesktopHostController {
    func comparisonModelPresentation(selectedModels: Set<String>) -> (String, [String]) {
        let states = comparisonModelStates()
        let models = states.filter { $0.unavailableReason == nil }.map {
            "\($0.option.id)\t\(DesktopHostModels.uiText($0.option.displayName))"
                + "\t\(DesktopHostModels.isLive($0.option.id) ? 1 : 0)"
                + "\t\(selectedModels.contains($0.option.id) ? 1 : 0)"
        }.joined(separator: "\n")
        let unavailable = states.compactMap { state -> String? in
            guard let reason = state.unavailableReason else { return nil }
            let saved = selectedModels.contains(state.option.id) ? " (saved selection retained)" : ""
            return "\(DesktopHostModels.uiText(state.option.displayName))\(saved): \(reason)"
        }
        return (models, unavailable)
    }

    func comparisonModelStates(
        options: [ModelCatalog.Option] = DesktopHostModels.visible
    ) -> [DesktopComparisonModelState] {
        var keys: [String: Result<String, Error>] = [:]
        return options.map { option in
            if DesktopHostModels.isLocal(option.id) {
                return .init(
                    option: option, key: "", unavailableReason: Platform.localReadiness(option.id, controller: self)
                )
            }
            let purpose: ModelCredentialPurpose = DesktopHostModels.isLive(option.id)
                ? .liveTranscription : .batchTranscription
            var key = ""
            do {
                if case .apiKey(let identifier, let provider) = ModelCredentialResolver.requirement(
                    for: option.id, purpose: purpose
                ) {
                    let result = keys[identifier] ?? Result { try effects.apiKey(name: identifier) }
                    keys[identifier] = result
                    do { key = try result.get() } catch {
                        throw DesktopHostError(
                            message: "Could not read the \(provider) API key: \(error.localizedDescription)"
                        )
                    }
                    let stored = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [identifier]
                    if case .missing(let name) = ModelCredentialResolver.availability(
                        for: option.id, purpose: purpose, storedAPIKeyIdentifiers: stored
                    ) { throw DesktopHostError(message: "No \(name) API key. Add it in Settings.") }
                }
                if DesktopHostModels.isLive(option.id) { try requireAzureResource(forLive: option.id) }
                return .init(option: option, key: key, unavailableReason: nil)
            } catch {
                return .init(option: option, key: "", unavailableReason: error.localizedDescription)
            }
        }
    }

    func comparisonAdmission(
        _ identifiers: [String], live: Bool, language: String?, generation: UUID
    ) throws -> DesktopComparisonConfiguration {
        let available = DesktopHostModels.visible
        let options = try identifiers.map { identifier in
            guard let option = available.first(where: { $0.id == identifier }),
                  DesktopHostModels.isLive(identifier) == live else {
                throw DesktopHostError(message: "A selected model is no longer available for this comparison mode.")
            }
            return option
        }
        let states = comparisonModelStates(options: options)
        let candidates = try states.map { state in
            if let reason = state.unavailableReason {
                throw DesktopHostError(message: "\(state.option.displayName): \(reason)")
            }
            return DesktopComparisonCandidate(
                modelID: state.option.id, displayName: state.option.displayName,
                providerName: DesktopHostModels.provider(for: state.option.id)?.displayName ?? "On-device"
            )
        }
        try DesktopComparisonRunner.validate(candidates)
        return DesktopComparisonConfiguration(
            selected: candidates, keys: Dictionary(uniqueKeysWithValues: states.map { ($0.option.id, $0.key) }),
            language: language, endpoint: azureResourceEndpoint(), deviceID: settings.microphoneDeviceID ?? "",
            generation: generation
        )
    }
}
