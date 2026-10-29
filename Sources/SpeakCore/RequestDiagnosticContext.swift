import Foundation

/// Persist only a caller-owned admission/observation snapshot. This type never
/// reads settings, credentials, clocks, request content or History identifiers.
public struct RequestDiagnosticContext: Codable, Equatable, Sendable {
    /// Admission is requested/resolved configuration, not proof that a provider
    /// received it. Observed handoff requires a receipt owned by this request.
    public enum Provenance: String, Codable, Sendable { case admission, observedHandoff }
    public enum Mode: String, Codable, Sendable { case live, batch, local, unknown }
    public enum Origin: String, Codable, Sendable { case global, focusOverride, explicitOverride, fallback, unknown }
    public enum Destination: String, Codable, Sendable { case history, clipboard, accessibility, none, unknown }
    public enum Stage: String, Codable, Sendable {
        case admission, providerHandoff, request, streaming, finalization, postProcessing, output, unknown
    }
    public enum FailureCode: String, Codable, Sendable {
        case unknown, cancelled, timeout, unavailable, authentication, permission
        case invalidInput, transport, missingCompletion
    }
    public enum FailureDomain: String, Codable, Sendable {
        case application, provider, transport, operatingSystem, unknown
    }
    public enum Outcome: String, Codable, Sendable {
        case started, succeeded, failed, cancelled, retry, fallback, unknown
    }

    public let provenance: Provenance
    public let model: ModelSelection
    public let postProcessingModel: ModelSelection
    public let observedProvider: ProviderSelection?
    public let mode: Mode
    public let origin: Origin
    public let language: LanguageSelection
    public let destination: Destination
    public let options: Options

    public init(
        provenance: Provenance = .admission, model: ModelSelection = .project(nil),
        postProcessingModel: ModelSelection = .project(nil), observedProvider: ProviderSelection? = nil,
        mode: Mode = .unknown, origin: Origin = .unknown, language: LanguageSelection = .project(nil),
        destination: Destination = .unknown, options: Options = .init()
    ) {
        self.provenance = provenance
        self.model = model
        self.postProcessingModel = postProcessingModel
        self.observedProvider = provenance == .observedHandoff ? observedProvider : nil
        self.mode = mode
        self.origin = origin
        self.language = language
        self.destination = destination
        self.options = options
    }

    /// Explicit keys are the export contract; adding a setting elsewhere cannot
    /// silently add it here. Nil means not recorded, never today's default.
    public struct Options: Codable, Equatable, Sendable {
        public let postProcessingEnabled: Bool?
        public let diarizationEnabled: Bool?
        public let streamingEnabled: Bool?
        public let speechSpeed: Double?
        public let finalizationBudgetMilliseconds: Int?

        public init(
            postProcessingEnabled: Bool? = nil, diarizationEnabled: Bool? = nil, streamingEnabled: Bool? = nil,
            speechSpeed: Double? = nil, finalizationBudgetMilliseconds: Int? = nil
        ) {
            self.postProcessingEnabled = postProcessingEnabled
            self.diarizationEnabled = diarizationEnabled
            self.streamingEnabled = streamingEnabled
            self.speechSpeed = speechSpeed.flatMap { $0.isFinite && (0.25...4).contains($0) ? $0 : nil }
            self.finalizationBudgetMilliseconds = Self.bounded(finalizationBudgetMilliseconds)
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: IssueDiagnosticOptionKeys.self)
            self.init(
                postProcessingEnabled: try values.decodeIfPresent(Bool.self, forKey: .postProcessingEnabled),
                diarizationEnabled: try values.decodeIfPresent(Bool.self, forKey: .diarizationEnabled),
                streamingEnabled: try values.decodeIfPresent(Bool.self, forKey: .streamingEnabled),
                speechSpeed: try values.decodeIfPresent(Double.self, forKey: .speechSpeed),
                finalizationBudgetMilliseconds: try values.decodeIfPresent(
                    Int.self, forKey: .finalizationBudgetMilliseconds
                )
            )
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: IssueDiagnosticOptionKeys.self)
            try values.encodeIfPresent(postProcessingEnabled, forKey: .postProcessingEnabled)
            try values.encodeIfPresent(diarizationEnabled, forKey: .diarizationEnabled)
            try values.encodeIfPresent(streamingEnabled, forKey: .streamingEnabled)
            try values.encodeIfPresent(speechSpeed, forKey: .speechSpeed)
            try values.encodeIfPresent(finalizationBudgetMilliseconds, forKey: .finalizationBudgetMilliseconds)
        }

        fileprivate static func bounded(_ value: Int?) -> Int? {
            value.flatMap { (0...86_400_000).contains($0) ? $0 : nil }
        }
    }

    public struct Failure: Codable, Equatable, Sendable {
        public let stage: Stage
        public let code: FailureCode
        public let domain: FailureDomain
        public let httpStatus: Int?

        public init(
            stage: Stage = .unknown, code: FailureCode = .unknown,
            domain: FailureDomain = .unknown, httpStatus: Int? = nil
        ) {
            self.stage = stage
            self.code = code
            self.domain = domain
            self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: IssueDiagnosticFailureKeys.self)
            self.init(stage: try values.decode(Stage.self, forKey: .stage),
                      code: try values.decode(FailureCode.self, forKey: .code),
                      domain: try values.decode(FailureDomain.self, forKey: .domain),
                      httpStatus: try values.decodeIfPresent(Int.self, forKey: .httpStatus))
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: IssueDiagnosticFailureKeys.self)
            try values.encode(stage, forKey: .stage)
            try values.encode(code, forKey: .code)
            try values.encode(domain, forKey: .domain)
            try values.encodeIfPresent(httpStatus, forKey: .httpStatus)
        }
    }

    public struct Event: Codable, Equatable, Sendable {
        public let stage: Stage
        public let outcome: Outcome
        public let elapsedMilliseconds: Int?

        public init(stage: Stage, outcome: Outcome, elapsedMilliseconds: Int? = nil) {
            self.stage = stage
            self.outcome = outcome
            self.elapsedMilliseconds = Options.bounded(elapsedMilliseconds)
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: IssueDiagnosticEventKeys.self)
            self.init(stage: try values.decode(Stage.self, forKey: .stage),
                      outcome: try values.decode(Outcome.self, forKey: .outcome),
                      elapsedMilliseconds: try values.decodeIfPresent(Int.self, forKey: .elapsedMilliseconds))
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: IssueDiagnosticEventKeys.self)
            try values.encode(stage, forKey: .stage)
            try values.encode(outcome, forKey: .outcome)
            try values.encodeIfPresent(elapsedMilliseconds, forKey: .elapsedMilliseconds)
        }
    }

    /// Validate native History admission without inventing observed handoffs.
    /// Shared by local codecs; report serialization still validates again.
    public static func admissionOnly(_ value: Self?) -> Self? {
        guard let value, value.provenance == .admission else { return nil }
        return value.sanitized
    }

    /// Reconstruct through validated boundaries immediately before export.
    /// Synthesized Decodable is intentionally not trusted as a privacy boundary.
    var sanitized: Self {
        Self(
            provenance: provenance, model: model.sanitized,
            postProcessingModel: postProcessingModel.sanitized,
            observedProvider: observedProvider.map { .project($0.identifier) }, mode: mode, origin: origin,
            language: .project(language.identifier), destination: destination,
            options: Options(
                postProcessingEnabled: options.postProcessingEnabled, diarizationEnabled: options.diarizationEnabled,
                streamingEnabled: options.streamingEnabled, speechSpeed: options.speechSpeed,
                finalizationBudgetMilliseconds: options.finalizationBudgetMilliseconds
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case provenance, model, postProcessingModel, observedProvider, mode, origin, language, destination, options
    }
}

private enum IssueDiagnosticOptionKeys: String, CodingKey {
    case postProcessingEnabled, diarizationEnabled, streamingEnabled, speechSpeed, finalizationBudgetMilliseconds
}
private enum IssueDiagnosticFailureKeys: String, CodingKey { case stage, code, domain, httpStatus }
private enum IssueDiagnosticEventKeys: String, CodingKey { case stage, outcome, elapsedMilliseconds }
