import Foundation
import SpeakCore

/// One bounded HTTPS POST. Hosts adapt the transport they already use for
/// cloud sync (URLSession on Linux, WinHTTP on Windows); nothing here touches
/// the audio path, and a failed request is dropped, never retried.
public protocol DesktopTelemetryHTTP: Sendable {
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> Int
}

/// Sends product analytics to PostHog EU with the Mac and Android envelope.
/// Events wait in a small in-memory queue, one request at a time, and are
/// dropped when it is full or a request fails. Nothing is written to disk, so
/// opting out (`purge`) leaves nothing behind. Without a project key (any build
/// that was not stamped with one) it never opens a connection.
public actor DesktopPostHogSink: ProductAnalyticsSink {
    public static let endpoint = URL(string: "https://eu.i.posthog.com/capture/")!
    public static let queueLimit = 50

    private let projectKey: String
    private let http: any DesktopTelemetryHTTP
    private let now: @Sendable () -> Date
    private var queue: [Data] = []
    private var isOpen = false
    private var generation = 0
    private var drain: Task<Void, Never>?

    public init(projectKey: String, http: any DesktopTelemetryHTTP, now: @escaping @Sendable () -> Date = Date.init) {
        self.projectKey = projectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
        self.now = now
    }

    public var isConfigured: Bool { !projectKey.isEmpty }

    public func reopen() async throws { isOpen = true }

    public func capture(_ payload: ProductAnalyticsPayload) async throws {
        guard isOpen, isConfigured, queue.count < Self.queueLimit else { return }
        queue.append(try Self.body(payload, projectKey: projectKey, timestamp: now()))
        guard drain == nil else { return }
        let current = generation
        drain = Task { await self.send(generation: current) }
    }

    public func purge() async throws {
        generation += 1
        queue.removeAll()
        drain?.cancel()
        drain = nil
    }

    public func close() async {
        isOpen = false
        try? await purge()
    }

    /// Waits for the queue to empty; used at clean exit and by tests.
    public func flush() async { await drain?.value }

    private func send(generation current: Int) async {
        while current == generation, !queue.isEmpty {
            let body = queue.removeFirst()
            _ = try? await http.post(Self.endpoint, headers: ["Content-Type": "application/json"], body: body)
        }
        if current == generation { drain = nil }
    }

    static func body(_ payload: ProductAnalyticsPayload, projectKey: String, timestamp: Date) throws -> Data {
        var properties = payload.properties.mapValues(\.foundationValue)
        properties["$geoip_disable"] = true
        properties["distinct_id"] = payload.distinctID?.uuidString ?? "anonymous-counter"
        properties["$lib"] = "just-speak-to-it"
        properties["$lib_version"] = "1"
        properties["timestamp"] = ISO8601DateFormatter().string(from: timestamp)
        let envelope: [String: Any] = ["api_key": projectKey, "event": payload.event, "properties": properties]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }
}

/// What a crash report says: a type and a scrubbed message, never a transcript,
/// key, path or user. `fatal` marks an abnormal exit or an unrecoverable error.
public struct DesktopCrashReport: Equatable, Sendable {
    public enum Level: String, Sendable { case error, fatal }

    public let type: String
    public let message: String
    public let level: Level
    public let tags: [String: String]

    public init(type: String, message: String, level: Level, tags: [String: String] = [:]) {
        self.type = DesktopTelemetryScrubber.scrub(type)
        self.message = DesktopTelemetryScrubber.scrub(message)
        self.level = level
        self.tags = tags
    }

    public init(error: Error, level: Level = .fatal) {
        let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        self.init(type: String(reflecting: Swift.type(of: error)), message: description, level: level)
    }

    public static let abnormalExit = DesktopCrashReport(
        type: "AbnormalExit", message: "The previous session ended without a clean shutdown.", level: .fatal,
        tags: ["report": "abnormal_exit"]
    )
}

/// Sentry envelopes for the EU project the iOS and Android apps use. A DSN only
/// permits sending events, so it is public by design.
public enum DesktopSentryEnvelope {
    public static let dsn =
        "https://0fe99ac203c91b80d4dfb0630ad7be7e@o4510682832240640.ingest.de.sentry.io/4510687487197264"
    public static let endpoint =
        URL(string: "https://o4510682832240640.ingest.de.sentry.io/api/4510687487197264/envelope/")!
    static let publicKey = "0fe99ac203c91b80d4dfb0630ad7be7e"
    static let client = "just-speak-to-it-desktop/1"

    public static var headers: [String: String] {
        [
            "Content-Type": "application/x-sentry-envelope",
            "X-Sentry-Auth": "Sentry sentry_version=7, sentry_key=\(publicKey), sentry_client=\(client)"
        ]
    }

    /// Only the fields below are sent: no user, server name, request,
    /// breadcrumbs, stack locals or device identifiers.
    public static func body(
        _ report: DesktopCrashReport, context: ProductAnalyticsContext, release: String, environment: String,
        eventID: UUID = UUID(), timestamp: Date = Date()
    ) throws -> Data {
        let id = eventID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let time = ISO8601DateFormatter().string(from: timestamp)
        let osName = context.platform == .windows ? "Windows" : "Linux"
        let platformTags = ["platform": context.platform.rawValue, "arch": context.architecture]
        let tags = report.tags.merging(platformTags) { tag, _ in tag }
        let event: [String: Any] = [
            "event_id": id,
            "timestamp": time,
            "platform": "native",
            "level": report.level.rawValue,
            "logger": "desktop",
            "release": release,
            "environment": environment,
            "tags": tags,
            "contexts": ["os": ["name": osName, "version": context.osMajorMinor]],
            "exception": ["values": [["type": report.type, "value": report.message]]]
        ]
        let payload = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let header = try JSONSerialization.data(
            withJSONObject: ["event_id": id, "sent_at": time, "dsn": dsn], options: [.sortedKeys]
        )
        let item = try JSONSerialization.data(
            withJSONObject: ["type": "event", "length": payload.count, "content_type": "application/json"],
            options: [.sortedKeys]
        )
        var body = Data()
        for part in [header, item, payload] {
            body.append(part)
            body.append(0x0A)
        }
        return body
    }
}
