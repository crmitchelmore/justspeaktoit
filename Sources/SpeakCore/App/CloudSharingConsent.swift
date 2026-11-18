import Foundation

// MARK: - Data kinds

/// What a cloud provider is allowed to receive. Consent for one kind does not
/// cover the others, even for the same provider.
public enum CloudSharedDataKind: String, Codable, CaseIterable, Sendable, Hashable {
    case audio
    case transcript
    case textToSpeak

    /// Short heading, for the settings list.
    public var title: String {
        switch self {
        case .audio: "Audio"
        case .transcript: "Transcript text"
        case .textToSpeak: "Text to speak"
        }
    }

    /// Phrase used in the sheet and the blocked message.
    public var phrase: String {
        switch self {
        case .audio: "your audio"
        case .transcript: "your transcript text"
        case .textToSpeak: "the text to speak"
        }
    }
}

// MARK: - On-device alternative

/// Whether the host can do a step without a cloud provider. The sheet offers
/// "Use on-device instead" only for a step this says it can do.
public struct CloudSharingOnDeviceAvailability: Equatable, Sendable {
    public var transcription: Bool
    public var postProcessing: Bool
    public var voice: Bool

    public init(transcription: Bool, postProcessing: Bool, voice: Bool) {
        self.transcription = transcription
        self.postProcessing = postProcessing
        self.voice = voice
    }

    /// No on-device substitute. The sheet shows Allow and Not now.
    public static let none = CloudSharingOnDeviceAvailability(
        transcription: false, postProcessing: false, voice: false
    )

    /// macOS: Apple Speech or a downloaded model, rules or local cleanup, and system speech.
    public static let apple = CloudSharingOnDeviceAvailability(
        transcription: true, postProcessing: true, voice: true
    )

    /// Android: the on-device recogniser, Gemini Nano or a downloaded model, and system speech.
    /// iOS voice output has no on-device provider, so iOS passes its own value.
    public static let android = CloudSharingOnDeviceAvailability(
        transcription: true, postProcessing: true, voice: true
    )
}

// MARK: - Request

/// One provider, and the data kinds a send or the current settings would give it.
public struct CloudSharingRequest: Equatable, Sendable, Identifiable, Hashable {
    public let provider: CloudSharingProvider
    public let kinds: [CloudSharedDataKind]
    public let canUseOnDevice: Bool
    public let purpose: ModelCredentialPurpose
    public let modelID: String?

    public var id: String {
        provider.id + ":" + purpose.cloudSharingID + ":" + kinds.map(\.rawValue).joined(separator: ",")
    }

    public init(
        provider: CloudSharingProvider,
        kinds: [CloudSharedDataKind],
        canUseOnDevice: Bool,
        purpose: ModelCredentialPurpose,
        modelID: String? = nil
    ) {
        var seen = Set<CloudSharedDataKind>()
        self.kinds = CloudSharedDataKind.allCases.filter { kinds.contains($0) && seen.insert($0).inserted }
        self.provider = provider
        self.canUseOnDevice = canUseOnDevice
        self.purpose = purpose
        self.modelID = modelID
    }

    /// "Allow Deepgram to receive your audio?"
    public var sheetTitle: String {
        "Allow \(provider.displayName) to receive \(kindsPhrase)?"
    }

    public var sheetMessage: String {
        "Just Speak to It is about to send \(kindsPhrase) to \(provider.displayName). "
            + "\(provider.displayName)'s privacy policy explains how they handle it. "
            + "Nothing is sent until you allow it, and you can withdraw this later in Privacy settings."
    }

    public var privacyPolicyLinkTitle: String { "\(provider.displayName) privacy policy" }

    /// "your audio and your transcript text", in kind order.
    public var kindsPhrase: String {
        switch kinds.count {
        case 0: return "this data"
        case 1: return kinds[0].phrase
        default:
            return kinds.dropLast().map(\.phrase).joined(separator: ", ") + " and " + (kinds.last?.phrase ?? "")
        }
    }
}

extension ModelCredentialPurpose {
    var cloudSharingID: String {
        switch self {
        case .liveTranscription: "live"
        case .batchTranscription: "batch"
        case .postProcessing: "cleanup"
        case .voiceOutput: "voice"
        }
    }

    fileprivate var cloudSharingKind: CloudSharedDataKind {
        switch self {
        case .liveTranscription, .batchTranscription: .audio
        case .postProcessing: .transcript
        case .voiceOutput: .textToSpeak
        }
    }

    fileprivate func canUseOnDevice(_ availability: CloudSharingOnDeviceAvailability) -> Bool {
        switch self {
        case .liveTranscription, .batchTranscription: availability.transcription
        case .postProcessing: availability.postProcessing
        case .voiceOutput: availability.voice
        }
    }
}

// MARK: - Consent

/// Per-provider, per-data-kind permission to send content to a cloud AI provider.
///
/// Stored on the device as `{"grants":{id:[kinds]},"version":1}`. It is never
/// exported, imported or synced: permission given on one device is not
/// permission for another. Missing or unreadable data grants nothing.
public struct CloudSharingConsent: Equatable, Sendable {
    public static let storageKey = "cloudSharingConsent"
    public static let formatVersion = 1
    public static let didChangeNotification = Notification.Name("CloudSharingConsentDidChange")

    public static let settingsTitle = "Cloud sharing"
    public static let settingsExplanation =
        "Audio, transcript text and text to speak are sent only to providers you allow. "
        + "Each provider is asked the first time something would be sent. Withdrawal takes effect immediately."
    public static let settingsEmpty =
        "No cloud providers are allowed yet. You'll be asked before anything is sent."
    public static let allowButton = "Allow"
    public static let notNowButton = "Not now"
    public static let useOnDeviceButton = "Use on-device instead"
    public static let withdrawButton = "Withdraw"

    public private(set) var grants: [String: Set<CloudSharedDataKind>]

    public init(grants: [String: Set<CloudSharedDataKind>] = [:]) {
        self.grants = grants.filter { !$0.value.isEmpty }
    }

    /// Fail closed: a missing, newer or unreadable document grants nothing.
    public init(json: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: json),
              envelope.version == Self.formatVersion else {
            grants = [:]
            return
        }
        var decoded: [String: Set<CloudSharedDataKind>] = [:]
        for (id, rawKinds) in envelope.grants {
            let kinds = Set(rawKinds.compactMap(CloudSharedDataKind.init(rawValue:)))
            if !id.isEmpty, !kinds.isEmpty { decoded[id] = kinds }
        }
        grants = decoded
    }

    public init(jsonString: String) {
        self.init(json: Data(jsonString.utf8))
    }

    /// `{"grants":{id:[kinds]},"version":1}`, kinds and provider ids in a stable order.
    public func encodedJSON() -> Data {
        let envelope = Envelope(
            grants: grants.keys.sorted().reduce(into: [:]) { result, id in
                result[id] = CloudSharedDataKind.allCases.filter { grants[id]?.contains($0) == true }.map(\.rawValue)
            },
            version: Self.formatVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(envelope)) ?? Data("{}".utf8)
    }

    public func encodedJSONString() -> String {
        String(data: encodedJSON(), encoding: .utf8) ?? "{\"grants\":{},\"version\":1}"
    }

    public func allows(_ request: CloudSharingRequest) -> Bool {
        guard !request.kinds.isEmpty else { return false }
        guard let granted = grants[request.provider.id] else { return false }
        return request.kinds.allSatisfy { granted.contains($0) }
    }

    public func allows(providerID: String, kind: CloudSharedDataKind) -> Bool {
        grants[providerID]?.contains(kind) == true
    }

    public func granting(_ request: CloudSharingRequest) -> CloudSharingConsent {
        var copy = self
        var kinds = copy.grants[request.provider.id] ?? []
        kinds.formUnion(request.kinds)
        copy.grants[request.provider.id] = kinds
        return copy
    }

    /// Removes every kind granted to `providerID`.
    public func withdrawing(providerID: String) -> CloudSharingConsent {
        var copy = self
        copy.grants[providerID] = nil
        return copy
    }

    /// Providers with at least one granted kind, in catalogue order.
    public var grantedProviders: [CloudSharingProvider] {
        CloudSharingProviderCatalogue.all.filter { grants[$0.id]?.isEmpty == false }
    }

    public func grantedKinds(for providerID: String) -> [CloudSharedDataKind] {
        CloudSharedDataKind.allCases.filter { grants[providerID]?.contains($0) == true }
    }

    /// Throws `CloudSharingBlocked` when `request` would leave the device without consent.
    /// A nil request stays on the device and is allowed.
    public func require(_ request: CloudSharingRequest?) throws {
        guard let request else { return }
        guard allows(request) else { throw CloudSharingBlocked(request: request) }
    }

    /// The cloud sends the current settings would make, one request per step.
    public static func requests(
        for inputs: PrivacyWorkflowInputs,
        availability: CloudSharingOnDeviceAvailability = .none
    ) -> [CloudSharingRequest] {
        let summary = PrivacyWorkflowSummary.make(inputs)
        var requests: [CloudSharingRequest] = []
        if summary.transcription.destination.leavesDevice {
            let model = inputs.usesBatchTranscription
                ? inputs.batchTranscriptionModelID : inputs.liveTranscriptionModelID
            let purpose: ModelCredentialPurpose = inputs.usesBatchTranscription
                ? .batchTranscription : .liveTranscription
            if let request = request(
                forModel: model, purpose: purpose, availability: availability,
                displayName: summary.transcription.destination.providerName
            ) {
                requests.append(request)
            }
        }
        if summary.postProcessing.destination.leavesDevice,
           let request = request(
               forModel: inputs.postProcessingModelID, purpose: .postProcessing, availability: availability,
               displayName: summary.postProcessing.destination.providerName
           ) {
            requests.append(request)
        }
        if summary.voiceOutput.destination.leavesDevice,
           let provider = CloudSharingProviderCatalogue.provider(id: inputs.voiceOutputProvider.rawValue)
           ?? CloudSharingProviderCatalogue.provider(
               matchingDisplayName: summary.voiceOutput.destination.providerName ?? ""
           ) {
            requests.append(CloudSharingRequest(
                provider: provider, kinds: [.textToSpeak],
                canUseOnDevice: availability.voice, purpose: .voiceOutput,
                modelID: inputs.voiceOutputProvider.rawValue
            ))
        }
        return requests
    }

    /// The provider one send would use, or nil when the send stays on the device.
    ///
    /// `appleSpeechMayUseAppleServers` covers macOS SpeechAnalyzer, which prefers
    /// on-device recognition but may send audio to Apple when that fails.
    /// Recorded audio whose model id is the legacy recogniser is transcribed
    /// through OpenRouter, matching `PrivacyWorkflowSummary`.
    public static func request(
        forModel modelID: String,
        purpose: ModelCredentialPurpose,
        availability: CloudSharingOnDeviceAvailability = .none,
        appleSpeechMayUseAppleServers: Bool = false
    ) -> CloudSharingRequest? {
        request(
            forModel: modelID, purpose: purpose, availability: availability,
            appleSpeechMayUseAppleServers: appleSpeechMayUseAppleServers, displayName: nil
        )
    }

    /// A send whose provider is already known (a TTS route, an Android catalogue id).
    public static func request(
        providerID: String,
        kind: CloudSharedDataKind,
        purpose: ModelCredentialPurpose,
        canUseOnDevice: Bool,
        modelID: String? = nil
    ) -> CloudSharingRequest? {
        guard let provider = CloudSharingProviderCatalogue.provider(id: providerID) else { return nil }
        return CloudSharingRequest(
            provider: provider, kinds: [kind], canUseOnDevice: canUseOnDevice, purpose: purpose, modelID: modelID
        )
    }

    /// What to tell a caller that must not upload: automation, an extension, or a dismissed sheet.
    public static func blockedMessage(for request: CloudSharingRequest) -> String {
        "Nothing was sent to \(request.provider.displayName). Open Just Speak to It and allow "
            + "\(request.kindsPhrase) to be sent to \(request.provider.displayName), "
            + "or choose an on-device option."
    }

    private static func request(
        forModel modelID: String,
        purpose: ModelCredentialPurpose,
        availability: CloudSharingOnDeviceAvailability,
        appleSpeechMayUseAppleServers: Bool = false,
        displayName: String?
    ) -> CloudSharingRequest? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let special = specialCaseProvider(
            modelID: trimmed, purpose: purpose, appleSpeechMayUseAppleServers: appleSpeechMayUseAppleServers
        ) {
            return CloudSharingRequest(
                provider: special, kinds: [purpose.cloudSharingKind],
                canUseOnDevice: purpose.canUseOnDevice(availability), purpose: purpose, modelID: trimmed
            )
        }
        let resolved = CloudSharingProviderCatalogue.provider(forModel: trimmed, purpose: purpose)
            ?? displayName.flatMap { CloudSharingProviderCatalogue.provider(matchingDisplayName: $0) }
        guard let provider = resolved else { return nil }
        return CloudSharingRequest(
            provider: provider, kinds: [purpose.cloudSharingKind],
            canUseOnDevice: purpose.canUseOnDevice(availability), purpose: purpose, modelID: trimmed
        )
    }

    /// Routes the privacy summary treats as cloud even when the credential resolver says on-device.
    private static func specialCaseProvider(
        modelID: String,
        purpose: ModelCredentialPurpose,
        appleSpeechMayUseAppleServers: Bool
    ) -> CloudSharingProvider? {
        if purpose == .batchTranscription, modelID == AppleLocalModels.legacySpeechModelID {
            return CloudSharingProviderCatalogue.provider(id: "openrouter")
        }
        if purpose == .liveTranscription, appleSpeechMayUseAppleServers,
           AppleLocalModels.isAppleSpeechModel(modelID) {
            return CloudSharingProviderCatalogue.provider(id: "apple")
        }
        return nil
    }

    private struct Envelope: Codable {
        var grants: [String: [String]]
        var version: Int
    }
}

/// A send that must not happen. `message` is safe to show; it names the provider and the data, not the content.
public struct CloudSharingBlocked: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let request: CloudSharingRequest

    public init(request: CloudSharingRequest) {
        self.request = request
    }

    public var message: String { CloudSharingConsent.blockedMessage(for: request) }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Stable automation ids shared by Apple, Android and, later, Windows and Linux.
public enum CloudSharingConsentAutomation {
    public static let sheet = "cloudSharingConsentSheet"
    public static let allowButton = "cloudSharingConsentAllowButton"
    public static let notNowButton = "cloudSharingConsentNotNowButton"
    public static let useOnDeviceButton = "cloudSharingConsentUseOnDeviceButton"
    public static let privacyPolicyLink = "cloudSharingConsentPrivacyPolicyLink"
    public static let settingsSection = "cloudSharingSettings"

    public static func withdrawButton(providerID: String) -> String {
        "cloudSharingWithdrawButton-\(providerID)"
    }
}
