import Foundation
import SpeakCore

/// A transcription model Compare Models can offer, with what it can do right
/// now on this Mac.
struct ComparisonCandidate: Identifiable, Hashable {
    enum Engine: Hashable {
        /// A shared `StreamingTranscriptionClient` route (cloud live models).
        case sharedStreamingClient(LiveTranscriptionRoute)
        /// A batch provider registered in `TranscriptionProviderRegistry`,
        /// or the OpenRouter fallback for catalogue ids no provider claims.
        case cloudBatch
        /// Apple SpeechAnalyzer (file and live) on macOS 26.
        case appleSpeechAnalyzer
        /// A downloaded WhisperKit-style model (file only).
        case downloadedLocal
    }

    var id: String { modelID }

    let modelID: String
    let displayName: String
    let providerDisplayName: String
    let engine: Engine
    let supportsStreaming: Bool
    let supportsFile: Bool
    /// Why the model cannot run right now, or `nil` when it can.
    let unavailableReason: String?

    var isUsable: Bool { unavailableReason == nil }

    func supports(_ mode: ModelComparisonInputMode) -> Bool {
        switch mode {
        case .streaming: return supportsStreaming
        case .file, .batch: return supportsFile
        }
    }
}

/// Builds the candidate list from the shared catalogues and this Mac's state.
///
/// Pure over its inputs so the rules stay testable: which models appear, the
/// mode each supports, and why an entry is greyed out.
enum ComparisonCandidateResolver {
    struct Environment {
        var storedAPIKeyIdentifiers: Set<String>
        var installedLocalModelIDs: Set<String>
        var azureEndpointConfigured: Bool
        var supportsSpeechTranscriber: Bool
        var supportsDictationTranscriber: Bool
    }

    static func candidates(in environment: Environment) -> [ComparisonCandidate] {
        var seen: Set<String> = []
        var result: [ComparisonCandidate] = []
        for candidate in appleCandidates(environment) + liveCandidates(environment)
            + batchCandidates(environment) + localCandidates(environment)
            where seen.insert(candidate.modelID).inserted {
            result.append(candidate)
        }
        return result
    }

    private static func appleCandidates(_ environment: Environment) -> [ComparisonCandidate] {
        let speech = ComparisonCandidate(
            modelID: AppleLocalModels.speechTranscriberModelID,
            displayName: "Apple SpeechTranscriber",
            providerDisplayName: "Apple",
            engine: .appleSpeechAnalyzer,
            supportsStreaming: true,
            supportsFile: true,
            unavailableReason: environment.supportsSpeechTranscriber
                ? nil : "Needs macOS 26 on an Apple Intelligence-capable Mac"
        )
        let dictation = ComparisonCandidate(
            modelID: AppleLocalModels.dictationTranscriberModelID,
            displayName: "Apple DictationTranscriber",
            providerDisplayName: "Apple",
            engine: .appleSpeechAnalyzer,
            supportsStreaming: true,
            supportsFile: true,
            unavailableReason: environment.supportsDictationTranscriber ? nil : "Needs macOS 26"
        )
        return [speech, dictation]
    }

    private static func liveCandidates(_ environment: Environment) -> [ComparisonCandidate] {
        ModelCatalog.remoteLiveTranscription.compactMap { option in
            guard let route = LiveTranscriptionRouting.route(for: option.id) else { return nil }
            // Apple routes are covered above; OpenAI's realtime transport is
            // platform-native and cannot share one microphone tap yet.
            guard route.provider != .apple, route.provider != .openai else { return nil }
            var reason = credentialReason(for: option.id, purpose: .liveTranscription, environment)
            if reason == nil, route.provider == .azure, !environment.azureEndpointConfigured {
                reason = "Add the Azure Speech endpoint in Settings › API Keys"
            }
            return ComparisonCandidate(
                modelID: option.id,
                displayName: option.displayName,
                providerDisplayName: route.provider.displayName,
                engine: .sharedStreamingClient(route),
                supportsStreaming: true,
                supportsFile: false,
                unavailableReason: reason
            )
        }
    }

    private static func batchCandidates(_ environment: Environment) -> [ComparisonCandidate] {
        ModelCatalog.batchTranscription.map { option in
            ComparisonCandidate(
                modelID: option.id,
                displayName: option.displayName,
                providerDisplayName: providerName(for: option.id),
                engine: .cloudBatch,
                supportsStreaming: false,
                supportsFile: true,
                unavailableReason: credentialReason(for: option.id, purpose: .batchTranscription, environment)
            )
        }
    }

    private static func localCandidates(_ environment: Environment) -> [ComparisonCandidate] {
        ModelCatalog.localTranscription.map { model in
            ComparisonCandidate(
                modelID: model.id,
                displayName: model.displayName,
                providerDisplayName: "On this Mac",
                engine: .downloadedLocal,
                supportsStreaming: false,
                supportsFile: true,
                unavailableReason: environment.installedLocalModelIDs.contains(model.id)
                    ? nil : "Not downloaded"
            )
        }
    }

    private static func credentialReason(
        for modelID: String,
        purpose: ModelCredentialPurpose,
        _ environment: Environment
    ) -> String? {
        switch ModelCredentialResolver.availability(
            for: modelID, purpose: purpose, storedAPIKeyIdentifiers: environment.storedAPIKeyIdentifiers
        ) {
        case .ready, .notRequired:
            return nil
        case .missing(let providerName):
            return "No \(providerName) API key"
        }
    }

    static func providerName(for modelID: String) -> String {
        let prefix = modelID.split(separator: "/").first.map(String.init) ?? modelID
        if let provider = LiveTranscriptionProviderID(rawValue: prefix.lowercased()) {
            return provider.displayName
        }
        switch prefix.lowercased() {
        case "groq": return "Groq"
        default: return prefix.prefix(1).uppercased() + prefix.dropFirst()
        }
    }
}
