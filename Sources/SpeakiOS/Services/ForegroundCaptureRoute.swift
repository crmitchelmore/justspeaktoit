#if os(iOS)
import Foundation
import SpeakCore

/// The model a foreground run records with, decided once before its session
/// exists: the offline on-device fallback (issue #999), then a check that the
/// resulting model can run. A model that cannot is reported, never replaced.
struct ForegroundCaptureRoute: Equatable {
    var modelID: String
    /// The cloud model this run would have used online, tagged for a later upgrade.
    var offlineIntendedModelID: String?
    /// The nonfatal notice an offline fallback shows for this run.
    var notice: String?
    var requiresStrictOnDeviceRecognition: Bool

    /// Throws ``iOSTranscriptionError/offlineLocalRecognitionUnavailable``
    /// when the run can neither reach its provider nor recognise on device,
    /// and whatever `requireAvailable` throws for the model the run would use.
    /// `localCapability` is only asked when the decision depends on it.
    static func resolve(
        requestedModelID: String,
        usesBatch: Bool,
        connectivity: CaptureConnectivitySnapshot,
        localCapability: () -> AppleLocalRecognitionCapability,
        requireAvailable: (String) throws -> Void
    ) throws -> Self {
        let capability = OfflineCaptureRouting.needsLocalCapability(
            usesBatch: usesBatch, requestedModelID: requestedModelID, connectivity: connectivity
        ) ? localCapability() : .unknown
        let decision = OfflineCaptureRouting.decide(
            usesBatch: usesBatch,
            requestedModelID: requestedModelID,
            binding: .ordinary,
            connectivity: connectivity,
            localCapability: capability
        )
        guard case .use(let offline) = decision else {
            throw iOSTranscriptionError.offlineLocalRecognitionUnavailable
        }
        try requireAvailable(offline.modelID)
        return Self(
            modelID: offline.modelID,
            offlineIntendedModelID: offline.notice == nil ? nil : requestedModelID,
            notice: offline.notice,
            requiresStrictOnDeviceRecognition: offline.requiresStrictOnDeviceRecognition
        )
    }

    /// Resolves the run's route from the user's settings.
    @MainActor
    static func resolve(
        settings: AppSettings, requestedModelID: String, usesBatch: Bool,
        connectivity: CaptureConnectivitySnapshot,
        localCapability: (String) -> AppleLocalRecognitionCapability
    ) throws -> Self {
        let localeIdentifier = TranscriptionLanguageCatalog.localeIdentifier(for: settings.preferredLocaleIdentifier)
        return try resolve(
            requestedModelID: requestedModelID, usesBatch: usesBatch, connectivity: connectivity,
            localCapability: { localCapability(localeIdentifier) },
            requireAvailable: { try settings.requireTranscriptionAvailable($0, usesBatch: usesBatch) }
        )
    }

    /// The production session for this route.
    @MainActor
    func makeSession(
        usesBatch: Bool, settings: AppSettings, audioSessionManager: AudioSessionManager
    ) throws -> IOSTranscriptionSession {
        try IOSTranscriptionSession(
            modelID: modelID,
            mode: usesBatch ? .batch(retainRecording: true) : .streaming,
            language: settings.preferredModelLanguage,
            audioSessionManager: audioSessionManager,
            batchAPIKey: settings.batchAPIKey,
            liveAPIKey: settings.liveAPIKey(for:),
            transcriptionKeywords: MetaMuseVoiceTranscribe.keywords(from: settings.transcriptionKeywords),
            requiresStrictOnDeviceRecognition: requiresStrictOnDeviceRecognition
        )
    }
}
#endif
