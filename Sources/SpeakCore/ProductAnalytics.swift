import Foundation

public enum AnalyticsConsentState: String, Codable, CaseIterable, Sendable {
    case unknown
    case optedIn
    case optedOut
    public var permitsCollection: Bool { self == .optedIn }
}

public enum AnalyticsPrivacyClass: String, Codable, Sendable {
    case anonymousCounter = "anonymous_counter"
    case pseudonymous
}

public enum AnalyticsPlatform: String, Codable, Sendable { case macOS, iOS }

public enum AnalyticsDistributionChannel: String, Codable, Sendable {
    case direct, homebrew
    case macAppStore = "mac_app_store"
    case testFlight = "testflight"
    case appStore = "app_store"
    case development
}

public enum AnalyticsOnboardingEntryPoint: String, Codable, Sendable {
    case freshInstall = "fresh_install"
    case reset
}

public enum AnalyticsOnboardingStep: String, Codable, Sendable {
    case welcome
    case microphonePermission = "microphone_permission"
    case providerChoice = "provider_choice"
    case hotkeySetup = "hotkey_setup"
    case analyticsChoice = "analytics_choice"
}

public enum AnalyticsProviderType: String, Codable, Sendable {
    case apple, azure, cartesia, deepgram, gladia, local, soniox, speechmatics, other
    case assemblyAI = "assembly_ai"
    case elevenLabs = "eleven_labs"
    case openAI = "openai"
}

public enum AnalyticsEngineType: String, Codable, Sendable {
    case onDevice = "on_device"
    case cloud
}

public enum AnalyticsCountBucket: String, Codable, Sendable {
    case zero = "0"
    case one = "1"
    case twoToFive = "2-5"
    case sixToTwenty = "6-20"
    case overTwenty = ">20"
}

public enum AnalyticsDaysSinceInstallBucket: String, Codable, Sendable {
    case zero = "0"
    case one = "1"
    case twoToSeven = "2-7"
    case eightToThirty = "8-30"
    case overThirty = ">30"
}

public enum AnalyticsOptInSurface: String, Codable, Sendable { case onboarding, settings }

public enum ProductAnalyticsEvent: Sendable, Equatable {
    case appActiveDaily
    case onboardingStarted(entryPoint: AnalyticsOnboardingEntryPoint)
    case onboardingStepCompleted(step: AnalyticsOnboardingStep)
    case onboardingCompleted(stepsSkipped: AnalyticsCountBucket)
    case firstTranscriptionSucceeded(
        provider: AnalyticsProviderType,
        engine: AnalyticsEngineType,
        daysSinceInstall: AnalyticsDaysSinceInstallBucket
    )
    case analyticsOptIn(surface: AnalyticsOptInSurface)

    public var name: String {
        switch self {
        case .appActiveDaily: "app_active_daily"
        case .onboardingStarted: "onboarding_started"
        case .onboardingStepCompleted: "onboarding_step_completed"
        case .onboardingCompleted: "onboarding_completed"
        case .firstTranscriptionSucceeded: "first_transcription_succeeded"
        case .analyticsOptIn: "analytics_opt_in"
        }
    }

    public var privacyClass: AnalyticsPrivacyClass { .pseudonymous }

    public var properties: [String: String] {
        switch self {
        case .appActiveDaily: [:]
        case let .onboardingStarted(entryPoint): ["entry_point": entryPoint.rawValue]
        case let .onboardingStepCompleted(step): ["step": step.rawValue]
        case let .onboardingCompleted(stepsSkipped): ["steps_skipped_bucket": stepsSkipped.rawValue]
        case let .firstTranscriptionSucceeded(provider, engine, daysSinceInstall):
            [
                "provider_type": provider.rawValue,
                "engine_type": engine.rawValue,
                "days_since_install_bucket": daysSinceInstall.rawValue
            ]
        case let .analyticsOptIn(surface): ["surface": surface.rawValue]
        }
    }
}

public struct ProductAnalyticsContext: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
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
        self.appVersion = appVersion
        self.build = build
        self.osMajorMinor = osMajorMinor
        self.distributionChannel = distributionChannel
        self.localeLanguageCode = localeLanguageCode
        self.architecture = architecture
    }
}

public struct ProductAnalyticsPayload: Codable, Equatable, Sendable {
    public let event: String
    public let distinctID: UUID
    public let privacyClass: AnalyticsPrivacyClass
    public let properties: [String: String]

    public init(event: ProductAnalyticsEvent, context: ProductAnalyticsContext, distinctID: UUID) {
        self.event = event.name
        self.distinctID = distinctID
        self.privacyClass = event.privacyClass
        self.properties = event.properties.merging([
            "platform": context.platform.rawValue,
            "app_version": context.appVersion,
            "build": context.build,
            "os_major_minor": context.osMajorMinor,
            "distribution_channel": context.distributionChannel.rawValue,
            "locale_language_code": context.localeLanguageCode,
            "architecture": context.architecture,
            "analytics_schema_version": String(ProductAnalyticsContext.schemaVersion)
        ]) { eventValue, _ in eventValue }
    }
}

public protocol ProductAnalyticsSink: Sendable {
    func capture(_ payload: ProductAnalyticsPayload) async throws
    func purge() async throws
    func close() async
}

public struct NoOpProductAnalyticsSink: ProductAnalyticsSink {
    public init() {}
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
}

public actor ProductAnalyticsController {
    private let context: ProductAnalyticsContext
    private let sink: any ProductAnalyticsSink
    private let stateStore: any ProductAnalyticsStateStore
    private let forceDisabled: @Sendable () -> Bool
    private var consent: AnalyticsConsentState

    public init(
        context: ProductAnalyticsContext,
        sink: any ProductAnalyticsSink,
        stateStore: any ProductAnalyticsStateStore,
        forceDisabled: @escaping @Sendable () -> Bool = { false }
    ) throws {
        self.context = context
        self.sink = sink
        self.stateStore = stateStore
        self.forceDisabled = forceDisabled
        self.consent = try stateStore.loadConsent()
    }

    public func consentState() -> AnalyticsConsentState { consent }

    public func setConsent(_ newConsent: AnalyticsConsentState) async throws {
        consent = newConsent
        try stateStore.saveConsent(newConsent)
        guard newConsent == .optedIn else {
            try await sink.purge()
            try stateStore.deleteInstallationID()
            await sink.close()
            return
        }
    }

    public func capture(_ event: ProductAnalyticsEvent) async throws {
        guard consent.permitsCollection, !forceDisabled() else { return }
        let distinctID = try installationID()
        try await sink.capture(ProductAnalyticsPayload(event: event, context: context, distinctID: distinctID))
    }

    public func preview(_ event: ProductAnalyticsEvent) throws -> Data {
        let zeroID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let payload = ProductAnalyticsPayload(
            event: event,
            context: context,
            distinctID: try stateStore.loadInstallationID() ?? zeroID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    private func installationID() throws -> UUID {
        if let existing = try stateStore.loadInstallationID() { return existing }
        let id = UUID()
        try stateStore.saveInstallationID(id)
        return id
    }
}
