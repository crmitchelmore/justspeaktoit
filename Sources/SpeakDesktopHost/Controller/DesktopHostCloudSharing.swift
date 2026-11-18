import Foundation
import SpeakCore
import SpeakDesktop

/// One AI provider as the native consent and withdrawal dialogs show it. The
/// words come from `CloudSharingConsent`, so every platform says the same thing.
package struct DesktopCloudSharingEntry: Sendable, Equatable {
    package let providerID: String
    package let name: String
    /// What the provider receives, one sentence per kind of content.
    package let detail: String
    /// Empty for a provider with no catalogued policy.
    package let privacyPolicyURL: String
    /// The accessible name of this provider's Withdraw button.
    package let withdrawLabel: String
}

/// The first-use question for providers that were not allowed yet.
package struct DesktopCloudSharingPrompt: Sendable, Equatable {
    package let title: String
    package let intro: String
    package let allowTitle: String
    package let notNowTitle: String
    package let entries: [DesktopCloudSharingEntry]
}

/// The providers the user has allowed, which they can withdraw one by one.
package struct DesktopCloudSharingPresentation: Sendable, Equatable {
    package let title: String
    package let footer: String
    package let emptyText: String
    package let entries: [DesktopCloudSharingEntry]
}

/// Which requests each desktop workflow sends to a provider.
package enum DesktopHostCloudSharing {
    /// Audio goes to the model's provider; on-device models send nothing.
    package static func transcription(model: String) -> CloudSharingRequest? {
        guard !DesktopHostModels.isLocal(model), let provider = DesktopHostModels.provider(for: model) else {
            return nil
        }
        return CloudSharingConsent.request(
            credentialIdentifier: provider.apiKeyIdentifier, providerName: provider.displayName, kind: .audio
        )
    }

    /// Transcript text goes to the cleanup model's provider only in remote mode.
    package static func postProcessing(_ options: DesktopPostProcessing.Options) -> CloudSharingRequest? {
        guard options.mode == .remote else { return nil }
        return postProcessing(model: options.modelIdentifier)
    }

    package static func postProcessing(model: String) -> CloudSharingRequest? {
        CloudSharingConsent.request(forModel: model, purpose: .postProcessing)
    }

    /// Text to speak goes to the voice's provider.
    package static func voice(_ speechVoice: DesktopSpeechVoice) -> CloudSharingRequest {
        voice(credentialIdentifier: speechVoice.apiKeyIdentifier)
    }

    package static func voice(credentialIdentifier: String) -> CloudSharingRequest {
        let id = CloudSharingProviderCatalogue.providerID(forCredentialIdentifier: credentialIdentifier)
        return CloudSharingConsent.request(
            credentialIdentifier: credentialIdentifier, providerName: id.capitalized, kind: .textToSpeak
        )
    }

    package static func entries(_ requests: [CloudSharingRequest]) -> [DesktopCloudSharingEntry] {
        requests.map { request in
            DesktopCloudSharingEntry(
                providerID: request.provider.id, name: request.provider.displayName,
                detail: request.kindLines.joined(separator: " "),
                privacyPolicyURL: request.provider.privacyPolicyURL?.absoluteString ?? "",
                withdrawLabel: "Withdraw consent for \(request.provider.displayName)"
            )
        }
    }

    package static func prompt(for requests: [CloudSharingRequest]) -> DesktopCloudSharingPrompt {
        DesktopCloudSharingPrompt(
            title: CloudSharingConsent.sheetTitle, intro: CloudSharingConsent.sheetIntro(for: requests),
            allowTitle: CloudSharingConsent.allowTitle, notNowTitle: CloudSharingConsent.notNowTitle,
            entries: entries(requests)
        )
    }

    package static func presentation(for consent: CloudSharingConsent) -> DesktopCloudSharingPresentation {
        DesktopCloudSharingPresentation(
            title: CloudSharingConsent.withdrawalTitle, footer: CloudSharingConsent.withdrawalFooter,
            emptyText: CloudSharingConsent.emptyWithdrawalText, entries: entries(consent.allowedRequests)
        )
    }
}

package extension DesktopCloudSharingConsentStore {
    /// Throws, before anything is sent, when a request is not allowed yet.
    func require(_ requests: [CloudSharingRequest]) throws {
        let missing = missing(CloudSharingConsent.merged(requests))
        if !missing.isEmpty { throw CloudSharingConsentRequiredError(requests: missing) }
    }

    func require(_ request: CloudSharingRequest?) throws {
        if let request { try require([request]) }
    }
}

extension DesktopHostController {
    /// Gates an upload on the user's consent. A missing consent asks the user
    /// when `prompt` is set (the user asked for this work) and always throws, so
    /// the work stops with nothing sent and its recording or text kept. An
    /// automation caller passes `prompt: false` and gets the one-line reason.
    package func requireCloudSharing(_ requests: [CloudSharingRequest?], prompt: Bool = true) throws {
        let needed = CloudSharingConsent.merged(requests.compactMap { $0 })
        let missing = cloudSharing.missing(needed)
        guard !missing.isEmpty else { return }
        guard prompt, !closed, askCloudSharing(missing) else {
            throw CloudSharingConsentRequiredError(requests: missing)
        }
        let names = PrivacyWorkflowSummary.formattedList(missing.map(\.provider.displayName))
        throw DesktopHostError(
            message: "Choose Allow to share with \(names), then try again. Nothing was sent."
        )
    }

    /// Requests for one dictation profile: the audio model, remote cleanup and
    /// Auto-Clean, which each send content to their own provider.
    /// `polish` is the profile's already captured Auto-Clean, so asking never reads a credential twice.
    package func cloudSharingRequests(
        for profile: DesktopProfileSession, polish: DesktopHostLivePolishInput?
    ) -> [CloudSharingRequest?] {
        var requests = [
            DesktopHostCloudSharing.transcription(model: profile.modelIdentifier),
            DesktopHostCloudSharing.postProcessing(profile.postProcessing)
        ]
        if let polish, DesktopPostProcessing.mode(for: polish.model) == .remote {
            requests.append(DesktopHostCloudSharing.postProcessing(model: polish.model))
        }
        return requests
    }

    /// The automation form of `requireCloudSharing`: it never opens a dialog
    /// for a caller that is not at the keyboard, sends nothing and says why.
    package func requireAutomationCloudSharing(_ requests: [CloudSharingRequest?]) throws {
        do { try requireCloudSharing(requests, prompt: false) } catch let error as CloudSharingConsentRequiredError {
            throw AutomationError(code: .transcriptionFailed, message: error.localizedDescription)
        }
    }

    /// Shows the native question. False when this host cannot show it.
    private func askCloudSharing(_ missing: [CloudSharingRequest]) -> Bool {
        let id = UUID()
        cloudSharingPrompt = (id, missing)
        do {
            try Platform.requestCloudSharingConsent(id: id, prompt: DesktopHostCloudSharing.prompt(for: missing))
            return true
        } catch {
            cloudSharingPrompt = nil
            return false
        }
    }

    package func answerCloudSharing(_ identifier: String, allow: Bool) {
        guard !closed else { return }
        guard let pending = cloudSharingPrompt, UUID(uuidString: identifier) == pending.id else {
            update("The sharing question is no longer current. Nothing was sent or allowed.")
            return
        }
        cloudSharingPrompt = nil
        let names = PrivacyWorkflowSummary.formattedList(pending.requests.map(\.provider.displayName))
        guard allow else {
            update("Nothing was sent to \(names). Choose an on-device model, or allow sharing when you are ready.")
            return
        }
        do {
            try cloudSharing.grant(pending.requests)
            update("Sharing with \(names) allowed. Try again to continue. You can withdraw this in Privacy settings.")
        } catch {
            update("Sharing with \(names) was not saved, so nothing was allowed: \(error.localizedDescription)")
        }
        publishCloudSharing()
    }

    package func withdrawCloudSharing(providerID: String) {
        guard !closed else { return }
        do {
            try cloudSharing.withdraw(providerID: providerID)
            let name = CloudSharingProviderCatalogue.provider(id: providerID)?.displayName ?? providerID
            update("Withdrew consent for \(name). Nothing more is sent to it until you allow it again.")
        } catch {
            update("Consent was not withdrawn: \(error.localizedDescription) Try again.")
        }
        publishCloudSharing()
    }

    /// Gives the native Privacy settings the providers currently allowed.
    package func publishCloudSharing() {
        guard !closed else { return }
        Platform.presentCloudSharing(DesktopHostCloudSharing.presentation(for: cloudSharing.consent))
    }
}
