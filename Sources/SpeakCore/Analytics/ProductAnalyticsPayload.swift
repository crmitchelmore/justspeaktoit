import Foundation

public struct ProductAnalyticsContext: Equatable, Sendable {
    public static let schemaVersion = 2
    public let platform: AnalyticsPlatform
    public let appVersion: String
    public let build: String
    public let osMajorMinor: String
    public let distributionChannel: AnalyticsDistributionChannel
    public let localeLanguageCode: String
    public let architecture: String

    public init(
        platform: AnalyticsPlatform,
        appVersion: String,
        build: String,
        osMajorMinor: String,
        distributionChannel: AnalyticsDistributionChannel,
        localeLanguageCode: String,
        architecture: String
    ) {
        self.platform = platform
        self.appVersion = Self.boundedVersion(appVersion)
        self.build = Self.boundedBuild(build)
        self.osMajorMinor = Self.boundedOperatingSystemVersion(osMajorMinor)
        self.distributionChannel = distributionChannel
        self.localeLanguageCode = Self.boundedLocaleLanguageCode(localeLanguageCode)
        self.architecture = Self.boundedArchitecture(architecture)
    }

    private static func boundedVersion(_ value: String) -> String {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 4).contains(components.count),
              components.allSatisfy({ Self.isBoundedDecimal($0, maximumLength: 5) })
        else { return "other" }
        return value
    }

    private static func boundedBuild(_ value: String) -> String {
        Self.isBoundedDecimal(value[...], maximumLength: 12) ? value : "other"
    }

    private static func boundedOperatingSystemVersion(_ value: String) -> String {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              components.allSatisfy({ Self.isBoundedDecimal($0, maximumLength: 3) })
        else { return "other" }
        return value
    }

    private static func boundedLocaleLanguageCode(_ value: String) -> String {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: "-")
        let language = normalized.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let supportedLanguages = Set(TranscriptionLanguageCatalog.options.compactMap { option -> String? in
            guard option.id != TranscriptionLanguageCatalog.automaticIdentifier else { return nil }
            return option.id.lowercased().split(separator: "_", maxSplits: 1).first.map(String.init)
        })
        return supportedLanguages.contains(language) ? language : "other"
    }

    private static func boundedArchitecture(_ value: String) -> String {
        let normalized = value.lowercased()
        return ["arm64", "x86_64"].contains(normalized) ? normalized : "other"
    }

    private static func isBoundedDecimal(_ value: Substring, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength
            && value.unicodeScalars.allSatisfy { (48 ... 57).contains(Int($0.value)) }
    }
}

public struct ProductAnalyticsPayload: Encodable, Equatable, Sendable {
    public let event: String
    public let distinctID: UUID?
    public let privacyClass: AnalyticsPrivacyClass
    public let properties: [String: AnalyticsPropertyValue]

    public init(event: ProductAnalyticsEvent, context: ProductAnalyticsContext, distinctID: UUID?) {
        self.event = event.name
        self.distinctID = event.privacyClass == .pseudonymous ? distinctID : nil
        self.privacyClass = event.privacyClass
        let contextProperties: [String: AnalyticsPropertyValue] = [
            "platform": .string(context.platform.rawValue),
            "app_version": .string(context.appVersion),
            "build": .string(context.build),
            "os_major_minor": .string(context.osMajorMinor),
            "distribution_channel": .string(context.distributionChannel.rawValue),
            "locale_language_code": .string(context.localeLanguageCode),
            "architecture": .string(context.architecture),
            "analytics_schema_version": .integer(ProductAnalyticsContext.schemaVersion)
        ]
        self.properties = event.properties.merging(contextProperties) { eventValue, _ in eventValue }
    }
}

public protocol ProductAnalyticsSink: Sendable {
    func reopen() async throws
    func capture(_ payload: ProductAnalyticsPayload) async throws
    func purge() async throws
    func close() async
}

public struct NoOpProductAnalyticsSink: ProductAnalyticsSink {
    public init() {}
    public func reopen() async throws {}
    public func capture(_: ProductAnalyticsPayload) async throws {}
    public func purge() async throws {}
    public func close() async {}
}

public protocol ProductAnalyticsStateStore: Sendable {
    func loadConsent() throws -> AnalyticsConsentState
    func saveConsent(_ consent: AnalyticsConsentState) throws
    func loadInstallationID() throws -> UUID?
    func saveInstallationID(_ id: UUID) throws
    func deleteInstallationID() throws
    func resetState() throws
}
