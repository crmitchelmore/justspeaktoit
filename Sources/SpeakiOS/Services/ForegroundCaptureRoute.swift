#if os(iOS)
import Foundation
import SpeakCore

/// The model a foreground run records with, decided once before its session
/// exists: the offline on-device fallback (issue #999), then the live route's
/// resolved model.
struct ForegroundCaptureRoute: Equatable {
    var modelID: String
    /// The cloud model this run would have used online, tagged for a later upgrade.
    var offlineIntendedModelID: String?
    /// The nonfatal notice an offline fallback shows for this run.
    var notice: String?
    var requiresStrictOnDeviceRecognition: Bool

    /// Throws ``iOSTranscriptionError/offlineLocalRecognitionUnavailable``
    /// when the run can neither reach its provider nor recognise on device.
    /// `localCapability` is only asked when the decision depends on it.
    static func resolve(
        requestedModelID: String,
        usesBatch: Bool,
        connectivity: CaptureConnectivitySnapshot,
        localCapability: () -> AppleLocalRecognitionCapability,
        resolveLiveModel: (String) -> String
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
        return Self(
            modelID: usesBatch ? offline.modelID : resolveLiveModel(offline.modelID),
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
            resolveLiveModel: { modelID in
                LiveTranscriptionRouting.resolvedModelID(
                    for: modelID,
                    apiKey: LiveTranscriptionRouting.route(for: modelID).map { settings.liveAPIKey(for: $0) }
                )
            }
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
