import Foundation

public extension RequestDiagnosticContext {
    /// One remote polish summary, not an attempt ledger or provider receipt.
    struct PostProcessingObservation: Codable, Equatable, Sendable {
        public let handoff: RequestDiagnosticContext?
        public let finalFailure: Failure?
        /// Only true is evidence. Nil means fallback was not recorded.
        public let fallbackObserved: Bool?

        public init(handoff: RequestDiagnosticContext? = nil, finalFailure: Failure? = nil,
                    fallbackObserved: Bool? = nil) {
            self.handoff = handoff.flatMap { value in
                guard value.provenance == .observedHandoff else { return nil }
                return RequestDiagnosticContext(
                    provenance: .observedHandoff, postProcessingModel: value.postProcessingModel.sanitized,
                    options: .init(streamingEnabled: value.options.streamingEnabled)
                )
            }
            self.finalFailure = finalFailure.flatMap { value in
                guard value.stage == .postProcessing else { return nil }
                return Failure(stage: .postProcessing, code: value.code, domain: value.domain,
                               httpStatus: value.httpStatus)
            }
            self.fallbackObserved = fallbackObserved == true ? true : nil
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: PostProcessingObservationKeys.self)
            self.init(handoff: try values.decodeIfPresent(RequestDiagnosticContext.self, forKey: .handoff),
                      finalFailure: try values.decodeIfPresent(Failure.self, forKey: .finalFailure),
                      fallbackObserved: try values.decodeIfPresent(Bool.self, forKey: .fallbackObserved))
        }

        var sanitized: Self {
            Self(handoff: handoff, finalFailure: finalFailure, fallbackObserved: fallbackObserved)
        }

    }
}

private enum PostProcessingObservationKeys: String, CodingKey { case handoff, finalFailure, fallbackObserved }
