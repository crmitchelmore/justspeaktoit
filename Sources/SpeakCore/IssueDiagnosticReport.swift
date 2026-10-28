import Foundation

/// One frozen allowlisted artifact. This does not upload, write files, read
/// secrets or collect context. Consumers preview these exact bytes, then ask
/// for per-report consent before copy/export/open; a URL is not an attachment.
public struct IssueDiagnosticReport: Sendable {
    public enum Section: String, CaseIterable, Codable, Sendable {
        case environment, models, options, failures, timeline
    }

    public static let attachmentFilename = "justspeaktoit-diagnostics.json"
    public static let maximumJSONBytes = 16 * 1_024
    public let title: String
    public let body: String
    public let jsonData: Data
    public let jsonString: String
    public let issueURL: URL?

    public init(
        context: RequestDiagnosticContext? = nil,
        recordedModels: [RequestDiagnosticContext.ModelSelection] = [],
        environment: RequestDiagnosticContext.Environment = .unavailable,
        failures: [RequestDiagnosticContext.Failure] = [],
        events: [RequestDiagnosticContext.Event] = [],
        omittedSections: Set<Section> = []
    ) {
        let payload = Payload(
            context: context, recordedModels: recordedModels, environment: environment,
            failures: failures, events: events, omittedSections: omittedSections
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let encoded = try? encoder.encode(payload)
        let accepted = encoded.flatMap { $0.count <= Self.maximumJSONBytes ? $0 : nil }
        // No byte slicing, partial JSON, raw encoding error or original payload
        // fallback. Failure itself is safe and visible on every output surface.
        let data = accepted ?? Data(#"{"schemaVersion":1,"reportState":"serializationUnavailable"}"#.utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let title = "Request issue — privacy-safe diagnostics"
        let body = """
        ## Description
        Describe the problem and reproduction steps here after reviewing these details.

        ## Request diagnostics
        These details contain only recorded allowlisted fields. Missing or invalid values are omitted.
        Legacy records do not establish request-time effective configuration.
        Recorded model IDs are not verified handoffs.
        No transcript, audio, raw errors, logs, persistent IDs or absolute timestamps are included.

        ```json
        \(json)
        ```

        Attach \(Self.attachmentFilename) manually if desired. Opening this draft does not upload the JSON attachment.
        Add your own reproduction steps after reviewing what you want to share.
        """
        self.title = title
        self.body = body
        self.jsonData = data
        self.jsonString = json
        var components = URLComponents(string: "https://github.com/crmitchelmore/justspeaktoit/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "bug")
        ]
        let url = components?.url
        self.issueURL = url.flatMap { $0.absoluteString.utf8.count <= 7_500 ? $0 : nil }
    }
}

private extension IssueDiagnosticReport {
    struct Truncation: Encodable {
        let recordedModels: Int
        let failures: Int
        let timeline: Int
    }

    struct Payload: Encodable {
        let schemaVersion = 1
        let contextState: String
        let context: RequestDiagnosticContext?
        let recordedModels: [RequestDiagnosticContext.ModelSelection]?
        let environment: RequestDiagnosticContext.Environment?
        let failures: [RequestDiagnosticContext.Failure]?
        let timeline: [RequestDiagnosticContext.Event]?
        let omittedSections: [Section]
        let omissionReason: String?
        let truncated: Truncation

        init(
            context: RequestDiagnosticContext?, recordedModels: [RequestDiagnosticContext.ModelSelection],
            environment: RequestDiagnosticContext.Environment, failures: [RequestDiagnosticContext.Failure],
            events: [RequestDiagnosticContext.Event], omittedSections: Set<Section>
        ) {
            let removeAll = omittedSections == Set(Section.allCases)
            self.contextState = removeAll ? "userRemoved" : context?.provenance.rawValue ?? "missingLegacyContext"
            self.context = (removeAll ? nil : context).map { value in
                let safe = value.sanitized
                return RequestDiagnosticContext(
                    provenance: safe.provenance, model: omittedSections.contains(.models) ? .project(nil) : safe.model,
                    postProcessingModel: omittedSections.contains(.models) ? .project(nil) : safe.postProcessingModel,
                    observedProvider: omittedSections.contains(.models) ? nil : safe.observedProvider,
                    mode: safe.mode, origin: safe.origin, language: safe.language, destination: safe.destination,
                    options: omittedSections.contains(.options) ? .init() : safe.options
                )
            }
            self.recordedModels = omittedSections.contains(.models) ? nil : recordedModels.prefix(8).map(\.sanitized)
            self.environment = omittedSections.contains(.environment) ? nil : .init(
                platform: environment.platform, architecture: environment.architecture, channel: environment.channel,
                appVersion: environment.appVersion, appBuild: environment.appBuild, osVersion: environment.osVersion,
                microphonePermission: environment.microphonePermission
            )
            self.failures = omittedSections.contains(.failures) ? nil : failures.prefix(8).map {
                .init(stage: $0.stage, code: $0.code, domain: $0.domain, httpStatus: $0.httpStatus)
            }
            self.timeline = omittedSections.contains(.timeline) ? nil : events.prefix(16).map {
                .init(stage: $0.stage, outcome: $0.outcome, elapsedMilliseconds: $0.elapsedMilliseconds)
            }
            self.omittedSections = Section.allCases.filter { omittedSections.contains($0) }
            self.omissionReason = omittedSections.isEmpty ? nil : "userRemoved"
            self.truncated = Truncation(
                recordedModels: omittedSections.contains(.models) ? 0 : max(0, recordedModels.count - 8),
                failures: omittedSections.contains(.failures) ? 0 : max(0, failures.count - 8),
                timeline: omittedSections.contains(.timeline) ? 0 : max(0, events.count - 16)
            )
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: IssueDiagnosticPayloadKeys.self)
            try values.encode(schemaVersion, forKey: .schemaVersion)
            try values.encode(contextState, forKey: .contextState)
            try values.encodeIfPresent(context, forKey: .context)
            try values.encodeIfPresent(recordedModels, forKey: .recordedModels)
            try values.encodeIfPresent(environment, forKey: .environment)
            try values.encodeIfPresent(failures, forKey: .failures)
            try values.encodeIfPresent(timeline, forKey: .timeline)
            try values.encode(omittedSections, forKey: .omittedSections)
            try values.encodeIfPresent(omissionReason, forKey: .omissionReason)
            try values.encode(truncated, forKey: .truncated)
        }
    }
}

private enum IssueDiagnosticPayloadKeys: String, CodingKey {
    case schemaVersion, contextState, context, recordedModels, environment, failures, timeline
    case omittedSections, omissionReason, truncated
}
