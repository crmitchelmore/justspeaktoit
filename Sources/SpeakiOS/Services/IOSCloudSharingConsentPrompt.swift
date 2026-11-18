#if os(iOS)
import Foundation
import SpeakCore

/// Explicit permission before the first send to each cloud AI provider (App
/// Store guideline 5.1.2(i), issue #1805).
///
/// Every iOS upload path asks this one object: recording starts (in the app,
/// the keyboard, Shortcuts and the Action Button), batch file uploads, polish
/// and read aloud. A refusal throws before anything leaves the device and
/// queues the providers in `pending`; the app shows the consent sheet while it
/// is non-empty, including after a background surface refused and the user
/// opened the app. Recordings that were already made stay on the device.
@MainActor
public final class IOSCloudSharingConsentPrompt: ObservableObject {
    public static let shared = IOSCloudSharingConsentPrompt(store: .shared)

    @Published public private(set) var pending: [CloudSharingRequest] = []
    public let store: CloudSharingConsentStore

    init(store: CloudSharingConsentStore) {
        self.store = store
    }

    /// Throws `CloudSharingConsentRequiredError`, and queues the sheet, when
    /// any of `requests` lacks consent.
    public func require(_ requests: [CloudSharingRequest]) throws {
        let missing = store.missing(requests)
        guard !missing.isEmpty else { return }
        pending = CloudSharingConsent.merged(pending + missing)
        throw CloudSharingConsentRequiredError(requests: missing)
    }

    /// The model's request, if it is a cloud model, checked as `require`.
    public func require(model: String, purpose: ModelCredentialPurpose) throws {
        try require([CloudSharingConsent.request(forModel: model, purpose: purpose)].compactMap { $0 })
    }

    /// Allow: records consent for everything asked. The user then retries.
    public func allow() {
        store.grant(pending)
        pending = []
    }

    /// Use on-device instead: Apple Speech for transcription and polish off,
    /// for the providers that were asked.
    public func useOnDevice(settings: AppSettings = .shared) {
        let ids = Set(pending.map(\.provider.id))
        let summary = PrivacyWorkflowSummary.make(
            settings: settings, voiceOutputEnabled: false, voiceOutputProvider: .deepgram
        )
        if let id = summary.transcription.providerID, ids.contains(id) {
            if settings.transcriptionLocation == .remote {
                settings.rememberedRemoteTranscriptionMode = settings.transcriptionMode
            }
            settings.selectLocalTranscriptionMode(.streaming)
        }
        if let id = summary.postProcessing.providerID, ids.contains(id) {
            settings.postProcessingEnabled = false
        }
        pending = []
    }

    public func dismiss() {
        pending = []
    }
}

/// For upload paths that are not on the main actor.
func requireCloudSharingConsent(model: String, purpose: ModelCredentialPurpose) async throws {
    try await MainActor.run {
        try IOSCloudSharingConsentPrompt.shared.require(model: model, purpose: purpose)
    }
}
#endif
