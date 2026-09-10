#if os(iOS)
import ActivityKit
import AVFoundation
import Foundation
import Speech
import SpeakCore

/// Remembers how the last capture on this device ended, so the health screen
/// can report a real earlier run rather than only what is true this second
/// (issue #997).
///
/// Two fields, both closed-set: an outcome label and a date. No transcript, no
/// error text, no provider, no route. Written to the App Group container so a
/// headless capture's outcome is visible to the app that shows the screen.
public enum CaptureOutcomeJournal {
    private static let outcomeKey = "captureHealth.lastOutcome.v1"
    private static let dateKey = "captureHealth.lastOutcomeAt.v1"

    static var defaults: UserDefaults? {
        AppGroupAvailability.verifiedDefaults() ?? UserDefaults.standard
    }

    public static func record(_ outcome: CaptureHealthLastOutcome, at date: Date = Date()) {
        guard let defaults else { return }
        defaults.set(outcome.rawValue, forKey: outcomeKey)
        defaults.set(date.timeIntervalSince1970, forKey: dateKey)
    }

    public static func last() -> (outcome: CaptureHealthLastOutcome, at: Date)? {
        guard let defaults,
              let raw = defaults.string(forKey: outcomeKey),
              let outcome = CaptureHealthLastOutcome(rawValue: raw)
        else { return nil }
        let stamp = defaults.double(forKey: dateKey)
        return (outcome, Date(timeIntervalSince1970: stamp))
    }

    /// Narrows a capture failure to the closed set. An error that is none of
    /// the named bounds becomes ``CaptureHealthLastOutcome/failed`` rather
    /// than being guessed into one of them.
    public static func outcome(for error: Error) -> CaptureHealthLastOutcome {
        if error is CancellationError { return .cancelled }
        guard let captureError = error as? iOSTranscriptionError else { return .failed }
        switch captureError {
        case .startTimedOut: return .startFailed
        case .microphoneDeliveredNoAudio: return .noInput
        case .finalisationTimedOut: return .finalisationTimedOut
        default: return .failed
        }
    }
}

/// Gathers the facts the Capture Health screen reports (issue #997).
///
/// The rows marked *exercised* are exercised here — an App Group value written
/// and read back, a keychain item's accessibility class read off the item
/// itself, a probe file created and removed where safety recordings live. The
/// rows marked *configuration* are permission and setting reads and are
/// labelled as such rather than dressed up as proof that capture works.
///
/// Nothing gathered here is free-form: the probe it fills in holds only enums,
/// booleans, whole numbers and dates, so no transcript, credential, device
/// name, route or file path can reach the screen. Nothing is transmitted.
@MainActor
public enum CaptureHealthProbeRunner {
    public static func gather(
        selfTest: CaptureSelfTestResult? = nil,
        now: Date = Date()
    ) async -> CaptureHealthProbe {
        var probe = CaptureHealthProbe(selfTest: selfTest)

        probe.microphone = self.microphonePermission()
        probe.speech = self.speechPermission()
        probe.appGroupRoundTrip = self.exerciseAppGroup()
        probe.recordingStorageRoundTrip = self.exerciseRecordingStorage()
        probe.liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

        let settings = AppSettings.shared
        await settings.ensureKeysLoaded()
        (probe.credentialLookup, probe.credentialAccessibility) = await self.exerciseCredentials(settings)
        probe.speechAssets = self.assetState(for: settings.selectedModel)

        let store = KeyboardInstantDictationStore.shared
        if let session = store.activeSession(now: now) {
            probe.keyboardHeartbeatAgeSeconds = Int(now.timeIntervalSince(session.lastHeartbeatAt))
        }

        if let last = CaptureOutcomeJournal.last() {
            probe.lastCaptureOutcome = last.outcome
            probe.lastCaptureAgeSeconds = Int(max(0, now.timeIntervalSince(last.at)))
        }

        let plan = CaptureRecoveryCoordinator.shared.refresh(now: now)
        probe.recoverableCaptureCount = plan.recoverable.count
        probe.uncertainCaptureCount = plan.uncertain.count

        return probe
    }

    // MARK: - Configuration reads

    private static func microphonePermission() -> CaptureHealthPermission {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    private static func speechPermission() -> CaptureHealthPermission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    // MARK: - Real exercises

    /// Writes a value into the shared container and reads it back, then
    /// removes it. This is what a headless trigger needs to work, and asking
    /// whether the entitlement exists would not prove it.
    private static func exerciseAppGroup() -> CaptureHealthExercise {
        guard let defaults = AppGroupAvailability.verifiedDefaults() else { return .failed }
        let key = "captureHealth.probe"
        let token = UUID().uuidString
        defaults.set(token, forKey: key)
        let readBack = defaults.string(forKey: key)
        defaults.removeObject(forKey: key)
        return readBack == token ? .succeeded : .failed
    }

    /// Creates, writes and removes a probe file where safety recordings are
    /// kept. A container that cannot be written to is the difference between
    /// audio surviving a crash and not.
    private static func exerciseRecordingStorage() -> CaptureHealthExercise {
        let url = AudioRecordingPersistence.recordingsDirectory
            .appendingPathComponent(".capture-health-probe")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data("probe".utf8).write(to: url, options: .atomic)
            let readBack = try Data(contentsOf: url)
            return readBack == Data("probe".utf8) ? .succeeded : .failed
        } catch {
            return .failed
        }
    }

    /// Reads the selected provider's key out of the keychain, and reads the
    /// stored item's own accessibility class back off the item (issue #930).
    private static func exerciseCredentials(
        _ settings: AppSettings
    ) async -> (CaptureHealthExercise?, CaptureHealthAccessibility?) {
        let accessibility = await AppSettings.canonicalCredentialStorage.storedAccessibility()
        let model = settings.selectedModel
        // An on-device model needs no key at all, and reporting a missing one
        // as a failure would be a red row for a configuration that works.
        guard IOSBatchTranscriptionRoute.route(for: model) != .appleSpeechAnalyzer else {
            return (nil, accessibility)
        }
        return (settings.batchAPIKey(for: model).isEmpty ? .failed : .succeeded, accessibility)
    }

    /// Whether an on-device speech model is even in play.
    ///
    /// The installed/downloading state of Apple's assets is deliberately left
    /// undetermined rather than guessed: asking for it means constructing the
    /// locale's speech modules, which is the work the capture start path is
    /// being pulled *away* from (issue #938), and a wrong green row here would
    /// be worse than an honest blank one.
    private static func assetState(for model: String) -> CaptureHealthAssetState? {
        IOSBatchTranscriptionRoute.route(for: model) == .appleSpeechAnalyzer ? nil : .notRequired
    }
}
#endif
