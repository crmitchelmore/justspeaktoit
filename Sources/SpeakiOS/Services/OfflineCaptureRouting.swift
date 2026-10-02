#if os(iOS)
import Foundation
import Speech
import SpeakCore

enum CaptureConnectivitySnapshot: Equatable, Sendable {
    case unknown
    case available
    case unavailable
}

enum AppleLocalRecognitionCapability: Equatable, Sendable {
    case unknown
    case available
    case unavailable
}

enum OfflineCaptureRequestBinding: Equatable, Sendable {
    case ordinary
    case explicitModel
    case keyboardProfile

    var requiresExactModel: Bool { self != .ordinary }
}

enum OfflineCaptureRefusal: Equatable, Sendable {
    case explicitRemoteModelUnavailable
    case localRecognitionUnavailable
}

struct OfflineCaptureRoute: Equatable, Sendable {
    let modelID: String
    let requiresStrictOnDeviceRecognition: Bool
    let notice: String?
}

enum OfflineCaptureRoutingDecision: Equatable, Sendable {
    case use(OfflineCaptureRoute)
    case refuse(OfflineCaptureRefusal)
}

/// Pure routing policy for live capture when the network path is known to be
/// unavailable. A satisfied path is not proof that a provider is reachable,
/// and an unknown path never authorises an offline substitution.
enum OfflineCaptureRouting {
    static let fallbackNotice = "Offline — using on-device speech recognition."

    static func needsLocalCapability(
        usesBatch: Bool,
        requestedModelID: String,
        connectivity: CaptureConnectivitySnapshot
    ) -> Bool {
        guard !usesBatch,
              let route = LiveTranscriptionRouting.route(for: requestedModelID),
              route.provider.isSupportedOnIOS else { return false }
        return route.provider == .apple || connectivity == .unavailable
    }

    static func decide(
        usesBatch: Bool,
        requestedModelID: String,
        binding: OfflineCaptureRequestBinding,
        connectivity: CaptureConnectivitySnapshot,
        localCapability: AppleLocalRecognitionCapability
    ) -> OfflineCaptureRoutingDecision {
        guard !usesBatch else { return self.unchanged(requestedModelID) }
        guard let route = LiveTranscriptionRouting.route(for: requestedModelID),
              route.provider.isSupportedOnIOS else {
            return self.unchanged(requestedModelID)
        }
        if route.provider == .apple {
            if route.modelID == AppleLocalModels.legacySpeechModelID,
               localCapability != .available {
                return .refuse(.localRecognitionUnavailable)
            }
            return .use(OfflineCaptureRoute(
                modelID: route.modelID,
                requiresStrictOnDeviceRecognition: true,
                notice: nil
            ))
        }
        guard connectivity == .unavailable else { return self.unchanged(route.modelID) }
        guard !binding.requiresExactModel else { return .refuse(.explicitRemoteModelUnavailable) }
        guard localCapability == .available else { return .refuse(.localRecognitionUnavailable) }
        return .use(OfflineCaptureRoute(
            modelID: AppleLocalModels.legacySpeechModelID,
            requiresStrictOnDeviceRecognition: true,
            notice: self.fallbackNotice
        ))
    }

    private static func unchanged(_ modelID: String) -> OfflineCaptureRoutingDecision {
        .use(OfflineCaptureRoute(
            modelID: modelID,
            requiresStrictOnDeviceRecognition: false,
            notice: nil
        ))
    }
}

@MainActor
enum AppleLegacyRecognitionCapabilityProbe {
    static func capability(for localeIdentifier: String) -> AppleLocalRecognitionCapability {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            return .unavailable
        }
        return recognizer.supportsOnDeviceRecognition ? .available : .unavailable
    }
}

enum AppleLegacyRecognitionRequestPolicy {
    static func requiresOnDeviceRecognition(
        strict: Bool,
        preferred: Bool,
        capability: AppleLocalRecognitionCapability
    ) throws -> Bool {
        if strict {
            guard capability == .available else {
                throw iOSTranscriptionError.offlineLocalRecognitionUnavailable
            }
            return true
        }
        return preferred && capability == .available
    }
}
#endif
