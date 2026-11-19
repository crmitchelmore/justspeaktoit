#if os(iOS)
import Foundation
import SpeakCore

/// Which backend a model ID and recording mode select. A pure decision made
/// before any transcriber exists, so both recording surfaces and their tests
/// read the same routing contract.
extension IOSTranscriptionSession {
    enum Mode: Equatable, Sendable {
        case streaming
        case batch(retainRecording: Bool)
    }

    enum BackendKind: Equatable, Sendable {
        case batch
        case apple
        case openAI
        case shared(LiveTranscriptionProviderID)
    }

    struct Resolution: Equatable, Sendable {
        let modelID: String
        let backend: BackendKind
        let route: LiveTranscriptionRoute?

        var isBatch: Bool { backend == .batch }
        var sampleRate: Int? { route?.sampleRate }

        /// The backend this routing decision already settled, for local
        /// startup diagnostics (issue #972). `nil` for Apple, which chooses
        /// between the analyzer and the legacy recogniser at start time and
        /// labels itself once it has.
        var resolvedStartupBackend: StartupBackend? {
            switch backend {
            case .batch: return .batch
            case .openAI: return .openAIRealtime
            case .shared: return .sharedClient
            case .apple: return nil
            }
        }
    }

    nonisolated static func resolve(modelID: String, mode: Mode) throws -> Resolution {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .batch = mode {
            return Resolution(modelID: trimmedModelID, backend: .batch, route: nil)
        }

        guard let route = LiveTranscriptionRouting.route(for: trimmedModelID) else {
            throw LiveTranscriptionClientError.unknownModel(trimmedModelID)
        }
        let backend: BackendKind
        switch route.provider {
        case .apple:
            backend = .apple
        case .openai:
            backend = .openAI
        default:
            guard route.provider.isSupportedOnIOS else {
                throw LiveTranscriptionClientError.providerNotAvailable(route.provider)
            }
            backend = .shared(route.provider)
        }
        return Resolution(modelID: route.modelID, backend: backend, route: route)
    }
}
#endif
