import Foundation
import SpeakCore

/// Device-local telemetry choices and identity, kept out of `settings.json` so
/// no preferences import, export or automation write can read or grant them.
public struct DesktopTelemetryState: Codable, Equatable, Sendable {
    public var analyticsConsent: AnalyticsConsentState = .unknown
    public var diagnosticsConsent: DiagnosticsConsentDecision = .undecided
    public var installationID: UUID?
    public var firstSeenDay: String?
    public var lastActiveDay: String?
    public var firstTranscriptionReported = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case analyticsConsent = "desktopAnalyticsConsent"
        case diagnosticsConsent = "desktopDiagnosticsConsent"
        case installationID, firstSeenDay, lastActiveDay, firstTranscriptionReported
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown or malformed consent values fail closed to "not decided".
        analyticsConsent = (try? container.decodeIfPresent(String.self, forKey: .analyticsConsent))
            .flatMap(AnalyticsConsentState.init(rawValue:)) ?? .unknown
        diagnosticsConsent = (try? container.decodeIfPresent(String.self, forKey: .diagnosticsConsent))
            .flatMap(DiagnosticsConsentDecision.init(rawValue:)) ?? .undecided
        installationID = try? container.decodeIfPresent(UUID.self, forKey: .installationID)
        firstSeenDay = try? container.decodeIfPresent(String.self, forKey: .firstSeenDay)
        lastActiveDay = try? container.decodeIfPresent(String.self, forKey: .lastActiveDay)
        firstTranscriptionReported =
            (try? container.decodeIfPresent(Bool.self, forKey: .firstTranscriptionReported)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(analyticsConsent.rawValue, forKey: .analyticsConsent)
        try container.encode(diagnosticsConsent.rawValue, forKey: .diagnosticsConsent)
        try container.encodeIfPresent(installationID, forKey: .installationID)
        try container.encodeIfPresent(firstSeenDay, forKey: .firstSeenDay)
        try container.encodeIfPresent(lastActiveDay, forKey: .lastActiveDay)
        try container.encode(firstTranscriptionReported, forKey: .firstTranscriptionReported)
    }
}

/// `telemetry.json` in the app data folder. A missing or unreadable file means
/// both consents are off, and nothing is ever sent before an explicit opt-in.
public final class DesktopTelemetryStore: ProductAnalyticsStateStore, @unchecked Sendable {
    public static let fileName = "telemetry.json"
    public let url: URL
    private let lock = NSLock()
    private var state: DesktopTelemetryState

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
        state = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(DesktopTelemetryState.self, from: $0) } ?? DesktopTelemetryState()
    }

    public func snapshot() -> DesktopTelemetryState { lock.withLock { state } }

    public func update(_ change: (inout DesktopTelemetryState) -> Void) throws {
        try lock.withLock {
            var next = state
            change(&next)
            guard next != state else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(next).write(to: url, options: .atomic)
            state = next
        }
    }

    public func loadConsent() throws -> AnalyticsConsentState { snapshot().analyticsConsent }
    public func saveConsent(_ consent: AnalyticsConsentState) throws { try update { $0.analyticsConsent = consent } }
    public func loadInstallationID() throws -> UUID? { snapshot().installationID }
    public func saveInstallationID(_ id: UUID) throws { try update { $0.installationID = id } }

    public func deleteInstallationID() throws {
        try update {
            $0.installationID = nil
            $0.lastActiveDay = nil
        }
    }

    public func resetState() throws {
        try update {
            $0.analyticsConsent = .unknown
            $0.installationID = nil
            $0.lastActiveDay = nil
        }
    }
}
