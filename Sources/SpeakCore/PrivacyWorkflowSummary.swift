import Foundation

// MARK: - Destination

/// Where a piece of user content ends up once the current settings are applied.
///
/// Privacy surfaces render this rather than provider capability metadata, so a
/// user reads what their own configuration does instead of what the app could
/// do in some other configuration.
public enum PrivacyDataDestination: Equatable, Sendable {
    /// Processing happens on the device; nothing is uploaded for this step.
    case onDevice
    /// Content is sent to the named cloud provider.
    case cloud(providerName: String)
    /// The step is switched off, so no content is sent for it at all.
    case disabled

    /// Provider that can receive content, or `nil` when this step cannot send it.
    public var providerName: String? {
        switch self {
        case .cloud(let providerName): return providerName
        case .onDevice, .disabled: return nil
        }
    }

    /// Short right-hand label for a settings row.
    public var label: String {
        switch self {
        case .onDevice: return "On device"
        case .cloud(let providerName): return providerName
        case .disabled: return "Off"
        }
    }

    /// Whether this step can send content off the device.
    public var leavesDevice: Bool { providerName != nil }
}

// MARK: - Inputs

/// The effective settings a privacy summary is derived from.
///
/// Kept as plain values so the projection is testable without a settings store,
/// a keychain or any UI.
public struct PrivacyWorkflowInputs: Equatable, Sendable {
    /// Whether recorded-audio (batch) transcription is the active mode.
    public var usesBatchTranscription: Bool
    /// Catalogue identifier of the selected live transcription model.
    public var liveTranscriptionModelID: String
    /// Catalogue identifier of the selected batch transcription model.
    public var batchTranscriptionModelID: String
    /// Whether transcripts are cleaned up after transcription.
    public var postProcessingEnabled: Bool
    /// Catalogue identifier of the selected post-processing model.
    public var postProcessingModelID: String
    /// Whether spoken replies are currently produced.
    public var voiceOutputEnabled: Bool
    /// The voice-output provider that receives the text to speak.
    public var voiceOutputProvider: VoiceOutputProvider
    /// Live SpeechAnalyzer may fall back to the legacy, cloud-capable recognizer.
    /// Set false only when the execution path explicitly disables that fallback.
    public var appleSpeechAnalyzerFallbackAllowed = true

    public init(
        usesBatchTranscription: Bool,
        liveTranscriptionModelID: String,
        batchTranscriptionModelID: String,
        postProcessingEnabled: Bool,
        postProcessingModelID: String,
        voiceOutputEnabled: Bool,
        voiceOutputProvider: VoiceOutputProvider
    ) {
        self.usesBatchTranscription = usesBatchTranscription
        self.liveTranscriptionModelID = liveTranscriptionModelID
        self.batchTranscriptionModelID = batchTranscriptionModelID
        self.postProcessingEnabled = postProcessingEnabled
        self.postProcessingModelID = postProcessingModelID
        self.voiceOutputEnabled = voiceOutputEnabled
        self.voiceOutputProvider = voiceOutputProvider
    }
}

// MARK: - Summary

/// The user's effective audio/text routing, projected from their settings.
///
/// Every destination is resolved through `ModelCredentialResolver`, which is the
/// same mapping the runtime clients and the model pickers use, so a newly
/// catalogued provider is disclosed automatically instead of needing a matching
/// edit to hand-written privacy copy.
public struct PrivacyWorkflowSummary: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let systemImage: String
        public let destination: PrivacyDataDestination
        public let detail: String
        /// True when this cloud destination is a permitted fallback, not an unconditional upload.
        public internal(set) var isConditionalCloud = false

        public init(
            id: String,
            title: String,
            systemImage: String,
            destination: PrivacyDataDestination,
            detail: String
        ) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.destination = destination
            self.detail = detail
        }

        /// Short right-hand label for a settings row.
        public var destinationLabel: String {
            isConditionalCloud ? "On device or " + destination.label : destination.label
        }
    }

    public let transcription: Row
    public let postProcessing: Row
    public let voiceOutput: Row

    /// Rows in the order the privacy screen presents them: audio first, then
    /// each text hop.
    public var rows: [Row] { [transcription, postProcessing, voiceOutput] }

    /// Providers that can receive content under the current settings, in row order
    /// and without duplicates.
    public var activeRecipients: [String] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let name = row.destination.providerName, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    // MARK: Projection

    public static func make(_ inputs: PrivacyWorkflowInputs) -> PrivacyWorkflowSummary {
        PrivacyWorkflowSummary(
            transcription: transcriptionRow(inputs),
            postProcessing: postProcessingRow(inputs),
            voiceOutput: voiceOutputRow(inputs)
        )
    }

    private static func transcriptionRow(_ inputs: PrivacyWorkflowInputs) -> Row {
        let selectedModelID = inputs.usesBatchTranscription
            ? inputs.batchTranscriptionModelID
            : inputs.liveTranscriptionModelID
        let modelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let purpose: ModelCredentialPurpose = inputs.usesBatchTranscription
            ? .batchTranscription
            : .liveTranscription
        let route = transcriptionDestination(for: modelID, inputs: inputs, purpose: purpose)
        let destination = route.destination
        let modelName = ModelCatalog.friendlyName(for: modelID)
        let title = inputs.usesBatchTranscription ? "Recorded audio" : "Live microphone audio"

        let detail: String
        switch destination {
        case .cloud(let providerName):
            if route.conditional {
                detail = "\(modelName) prefers on-device recognition. If it is unavailable or fails, audio may be sent "
                    + "to \(providerName) for transcription."
            } else {
                detail = inputs.usesBatchTranscription
                    ? "Your recording is uploaded to \(providerName) and transcribed with \(modelName)."
                    : "Your microphone audio is streamed to \(providerName) and transcribed with \(modelName)."
            }
        case .onDevice, .disabled:
            detail = "\(modelName) transcribes your audio on this device; it is not uploaded for transcription."
        }

        var row = Row(
            id: "transcription",
            title: title,
            systemImage: destination.leavesDevice ? "waveform.badge.magnifyingglass" : "iphone.gen3",
            destination: destination,
            detail: detail
        )
        row.isConditionalCloud = route.conditional
        return row
    }

    private static func transcriptionDestination(
        for modelID: String,
        inputs: PrivacyWorkflowInputs,
        purpose: ModelCredentialPurpose
    ) -> (destination: PrivacyDataDestination, conditional: Bool) {
        if inputs.usesBatchTranscription {
            // iOS only implements SpeechAnalyzer as a local batch route. An
            // older persisted SFSpeechRecognizer ID falls through to OpenRouter.
            if modelID == AppleLocalModels.legacySpeechModelID {
                return (.cloud(providerName: "OpenRouter"), false)
            }
        } else if modelID == AppleLocalModels.legacySpeechModelID
            || (AppleLocalModels.isSpeechAnalyzerModel(modelID) && inputs.appleSpeechAnalyzerFallbackAllowed) {
            return (.cloud(providerName: "Apple"), true)
        }
        return (resolveDestination(for: modelID, purpose: purpose), false)
    }

    private static func postProcessingRow(_ inputs: PrivacyWorkflowInputs) -> Row {
        let destination: PrivacyDataDestination = inputs.postProcessingEnabled
            ? resolveDestination(for: inputs.postProcessingModelID, purpose: .postProcessing)
            : .disabled
        let modelName = ModelCatalog.friendlyName(for: inputs.postProcessingModelID)

        let detail: String
        switch destination {
        case .disabled:
            detail = "Post-processing is off, so your transcript text is not sent anywhere to be cleaned up."
        case .cloud(let providerName):
            detail = "Your transcript text is sent to \(providerName) and cleaned up with \(modelName)."
        case .onDevice:
            detail = "\(modelName) cleans up your transcript on this device; the text is not uploaded."
        }

        return Row(
            id: "postProcessing",
            title: "Transcript clean-up",
            systemImage: destination.leavesDevice ? "text.badge.checkmark" : "iphone.gen3",
            destination: destination,
            detail: detail
        )
    }

    private static func voiceOutputRow(_ inputs: PrivacyWorkflowInputs) -> Row {
        let providerName = inputs.voiceOutputProvider.displayName
        let destination: PrivacyDataDestination = inputs.voiceOutputEnabled
            ? .cloud(providerName: providerName)
            : .disabled

        let detail: String
        if inputs.voiceOutputEnabled {
            detail = "The reply text spoken aloud is sent to \(providerName) to be synthesised."
        } else {
            detail = "Voice output is off, so no text is sent to be spoken. Turning it on sends the reply "
                + "text to \(providerName)."
        }

        return Row(
            id: "voiceOutput",
            title: "Spoken replies",
            systemImage: destination.leavesDevice ? "speaker.wave.2" : "speaker.slash",
            destination: destination,
            detail: detail
        )
    }

    private static func resolveDestination(
        for modelID: String,
        purpose: ModelCredentialPurpose
    ) -> PrivacyDataDestination {
        switch ModelCredentialResolver.requirement(for: modelID, purpose: purpose) {
        case .notRequired:
            return .onDevice
        case .apiKey(_, let providerName):
            return .cloud(providerName: providerName)
        }
    }
}

// MARK: - Catalogue-derived disclosures

public extension PrivacyWorkflowSummary {
    /// Every provider a user can pick for voice output on this platform, in
    /// catalogue order. Derived from `VoiceOutputProvider` so a provider added
    /// to the router cannot be left out of the disclosure.
    static var voiceOutputRecipients: [String] {
        VoiceOutputProvider.allCases.map(\.displayName)
    }

    /// Sentence naming every selectable voice-output recipient.
    static var voiceOutputDisclosure: String {
        "Voice output sends the text it speaks to whichever provider you select: "
            + formattedList(voiceOutputRecipients) + "."
    }

    /// Sentence covering both optional text hops, for surfaces that show one
    /// combined line.
    static var textDisclosure: String {
        "When enabled, post-processing sends transcript text to OpenRouter. " + voiceOutputDisclosure
    }

    /// "A", "A and B", "A, B and C".
    static func formattedList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}
