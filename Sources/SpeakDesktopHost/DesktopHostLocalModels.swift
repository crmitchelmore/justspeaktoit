import Foundation
import SpeakCore
import SpeakDesktop

/// Hooks the controller calls into a host's History sync once it is configured.
package struct DesktopHostSyncHooks: Sendable {
    package var historyChanged: (@Sendable () -> Void)?
    /// Saves a provider key typed in Settings or the post-processing dialog
    /// (removes it when empty) and marks it saved by hand in the same step, so
    /// a key imported from the Mac and deleted there cannot take a newly typed
    /// key with it.
    package var saveKeyByHand: (@Sendable (_ value: String, _ identifier: String) async throws -> Void)?

    package init(
        historyChanged: (@Sendable () -> Void)? = nil,
        saveKeyByHand: (@Sendable (_ value: String, _ identifier: String) async throws -> Void)? = nil
    ) {
        self.historyChanged = historyChanged
        self.saveKeyByHand = saveKeyByHand
    }
}

/// Where a transcript synced from another device came from.
package enum DesktopHostSync {
    /// A friendly name for the device a synced transcript came from.
    package static func originName(_ platform: String?) -> String {
        switch platform {
        case "macos": return "your Mac"
        case "ios": return "your iPhone"
        case "windows": return "another PC"
        case "linux": return "a Linux computer"
        default: return "another device"
        }
    }
}

// Hosts without an on-device runtime keep no local-model state and list no
// local models, so these defaults are never reached through the UI.
package extension DesktopHostPlatform where LocalModelsState == Void {
    static func makeLocalModelsState() {}
}

// Hosts without Read aloud keep no state and never speak.
package extension DesktopHostPlatform where ReadAloudState == Void {
    static func makeReadAloudState() {}
    static func stopReadAloud(_ state: inout Void, playback: Playback) {}
    static func isReadingAloud(_ state: Void) -> Bool { false }
}

package extension DesktopHostPlatform {
    static var localDeviceName: String { "this computer" }

    static func localReadiness(_ model: String, controller: isolated DesktopHostController<Self>) -> String? {
        "This on-device model is not available in this \(displayName) build."
    }

    static func transcribeLocally(
        _ audio: URL, model: String, language: String?, controller: isolated DesktopHostController<Self>
    ) async throws -> TranscriptionResult {
        throw DesktopTranscriptionError.unsupportedModel
    }

    static func beginLocalUse(_ model: String, controller: isolated DesktopHostController<Self>) -> String? { nil }

    static func endLocalUse(_ held: String, controller: isolated DesktopHostController<Self>) {}
}

extension DesktopHostController {
    /// Holds `model` while a recording, import or transcription uses it, when
    /// it is an on-device model; pass the result to `endLocalUse`.
    package func beginLocalUse(_ model: String) -> String? { Platform.beginLocalUse(model, controller: self) }

    package func endLocalUse(_ held: String?) {
        if let held { Platform.endLocalUse(held, controller: self) }
    }

    /// The key a remote model needs, or an empty key after checking that an
    /// on-device model can run. Throws with the user-facing reason otherwise.
    @discardableResult
    package func requireCredentialOrLocalModel(_ model: String) throws -> String {
        if DesktopHostModels.isLocal(model) {
            if let problem = Platform.localReadiness(model, controller: self) {
                throw DesktopHostError(message: problem)
            }
            return ""
        }
        let key = try effects.apiKey(name: credentialIdentifier(for: model))
        guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
        return key
    }

    /// The key for a remote model's batch request; on-device models need none.
    package func transcriptionKey(for model: String) throws -> String {
        DesktopHostModels.isLocal(model) ? "" : try effects.apiKey(name: credentialIdentifier(for: model))
    }

    /// The upload cap is a provider limit; on-device audio never leaves this computer.
    package func checkUploadSize(_ audio: URL, model: String) throws {
        guard !DesktopHostModels.isLocal(model) else { return }
        let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 25_000_000 else {
            throw DesktopHostError(
                message: "Audio exceeds this \(Platform.displayName) preview\u{2019}s 25 MB upload cap. "
                    + "The recording is saved."
            )
        }
    }

    package func transcribingStatus(for model: String) -> String {
        DesktopHostModels.isLocal(model)
            ? "Transcribing on \(Platform.localDeviceName)\u{2026} Your recording is saved locally."
            : "Transcribing\u{2026} Your recording is saved locally."
    }

    /// The live, on-device or remote batch slot restores this model when the
    /// user switches Source or Mode again.
    package func rememberModelSlot() {
        if DesktopHostModels.isLive(settings.model) {
            settings.liveModel = settings.model
        } else if DesktopHostModels.isLocal(settings.model) {
            settings.localModel = settings.model
        } else {
            settings.batchModel = settings.model
        }
    }

    package func readyStatus(savedRecordings: Int) throws -> String {
        let hint = Platform.readyHint(hotKeySettings())
        if DesktopHostModels.isLocal(settings.model) {
            return Platform.localReadiness(settings.model, controller: self)
                ?? "Ready on \(Platform.localDeviceName). \(hint) \(savedRecordings) saved recordings."
        }
        let key = try Platform.apiKey(name: credentialIdentifier(for: settings.model))
        return key.isEmpty ? "Enter and save the selected provider\u{2019}s API key to record or import audio."
            : "Ready. \(hint) \(savedRecordings) saved recordings."
    }

    /// A transcript synced from another device has no audio here.
    package func refuseSyncedAudio(_ record: DesktopRecordingStore.Record) -> Bool {
        guard record.isSyncedCopy else { return false }
        update("This transcript was synced from \(DesktopHostSync.originName(record.originPlatform)). "
            + "Its audio stays on that device, so it cannot be played, opened or transcribed again here.")
        return true
    }
}
