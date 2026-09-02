// Event catalogue, payload boundary and controller stay together so the privacy contract can be audited as one unit.
// swiftlint:disable file_length
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
    case apple, azure, cartesia, deepgram, gladia, groq, local, meta, mistral, modulate, soniox, speechmatics, other
    case assemblyAI = "assembly_ai"
    case elevenLabs = "eleven_labs"
    case openAI = "openai"
    case openRouter = "openrouter"
    case revAI = "rev_ai"
    case xAI = "xai"

    private static let liveProviderMapping: [LiveTranscriptionProviderID: AnalyticsProviderType] = [
        .apple: .apple,
        .deepgram: .deepgram,
        .cartesia: .cartesia,
        .gladia: .gladia,
        .modulate: .modulate,
        .assemblyai: .assemblyAI,
        .soniox: .soniox,
        .elevenlabs: .elevenLabs,
        .openai: .openAI,
        .speechmatics: .speechmatics,
        .xai: .xAI,
        .meta: .meta
    ]

    public init(liveProvider: LiveTranscriptionProviderID) {
        self = Self.liveProviderMapping[liveProvider] ?? .other
    }
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
    case onboardingPermissionResult(permission: AnalyticsPermissionType, state: AnalyticsPermissionState)
    case onboardingCompleted(stepsSkipped: AnalyticsCountBucket)
    case firstTranscriptionSucceeded(
        provider: AnalyticsProviderType,
        engine: AnalyticsEngineType,
        daysSinceInstall: AnalyticsDaysSinceInstallBucket
    )
    case transcriptionStarted(AnalyticsTranscriptionDimensions)
    case transcriptionCompleted(
        AnalyticsTranscriptionDimensions,
        duration: AnalyticsDurationBucket,
        wordCount: AnalyticsWordCountBucket,
        latency: AnalyticsLatencyBucket,
        output: AnalyticsOutputMethod
    )
    case transcriptionFailed(
        AnalyticsTranscriptionDimensions,
        error: AnalyticsErrorCategory,
        stage: AnalyticsPipelineStage
    )
    case transcriptionCancelled(AnalyticsTranscriptionDimensions, duration: AnalyticsDurationBucket)
    case polishCompleted(
        engine: AnalyticsEngineType,
        provider: AnalyticsProviderType,
        latency: AnalyticsLatencyBucket,
        preset: AnalyticsPolishPreset
    )
    case polishFailed(
        engine: AnalyticsEngineType,
        provider: AnalyticsProviderType,
        latency: AnalyticsLatencyBucket,
        preset: AnalyticsPolishPreset,
        error: AnalyticsErrorCategory
    )
    case correctionApplied(rulesMatched: AnalyticsCountBucket)
    case correctionRuleCreated(totalRules: AnalyticsCountBucket)
    case profileActivated(profileCount: AnalyticsCountBucket, isDefault: Bool)
    case insightsViewed(surface: AnalyticsSurface)
    case historyAction(AnalyticsHistoryAction)
    case voiceOutputUsed(engine: AnalyticsEngineType, provider: AnalyticsProviderType)
    case sendToMacCompleted(success: Bool, latency: AnalyticsLatencyBucket)
    case modelDownloadCompleted(modelFamily: AnalyticsModelFamily, size: AnalyticsModelSizeBucket, success: Bool)
    case keyboardEnabledState(enabled: Bool)
    case providerConfigured(provider: AnalyticsProviderType, method: AnalyticsProviderConfigurationMethod)
    case settingsChanged(setting: AnalyticsSettingID, category: AnalyticsSettingCategory)
    case errorDisplayed(error: AnalyticsErrorCategory, surface: AnalyticsSurface)
    case analyticsOptIn(surface: AnalyticsOptInSurface)

    public var name: String {
        switch self {
        case .appActiveDaily: "app_active_daily"
        case .onboardingStarted: "onboarding_started"
        case .onboardingStepCompleted: "onboarding_step_completed"
        case .onboardingPermissionResult: "onboarding_permission_result"
        case .onboardingCompleted: "onboarding_completed"
        case .firstTranscriptionSucceeded: "first_transcription_succeeded"
        case .transcriptionStarted: "transcription_started"
        case .transcriptionCompleted: "transcription_completed"
        case .transcriptionFailed: "transcription_failed"
        case .transcriptionCancelled: "transcription_cancelled"
        case .polishCompleted: "polish_completed"
        case .polishFailed: "polish_failed"
        case .correctionApplied: "correction_applied"
        case .correctionRuleCreated: "correction_rule_created"
        case .profileActivated: "profile_activated"
        case .insightsViewed: "insights_viewed"
        case .historyAction: "history_action"
        case .voiceOutputUsed: "voice_output_used"
        case .sendToMacCompleted: "send_to_mac_completed"
        case .modelDownloadCompleted: "model_download_completed"
        case .keyboardEnabledState: "keyboard_enabled_state"
        case .providerConfigured: "provider_configured"
        case .settingsChanged: "settings_changed"
        case .errorDisplayed: "error_displayed"
        case .analyticsOptIn: "analytics_opt_in"
        }
    }

    public var privacyClass: AnalyticsPrivacyClass {
        switch self {
        case .correctionApplied, .errorDisplayed: .anonymousCounter
        default: .pseudonymous
        }
    }

    public var properties: [String: AnalyticsPropertyValue] {
        switch self {
        case .appActiveDaily: [:]
        case let .onboardingStarted(entryPoint): ["entry_point": .string(entryPoint.rawValue)]
        case let .onboardingStepCompleted(step): ["step": .string(step.rawValue)]
        case let .onboardingPermissionResult(permission, state):
            ["permission": .string(permission.rawValue), "state": .string(state.rawValue)]
        case let .onboardingCompleted(stepsSkipped): ["steps_skipped_bucket": .string(stepsSkipped.rawValue)]
        case let .firstTranscriptionSucceeded(provider, engine, daysSinceInstall):
            [
                "provider_type": .string(provider.rawValue),
                "engine_type": .string(engine.rawValue),
                "days_since_install_bucket": .string(daysSinceInstall.rawValue)
            ]
        case let .transcriptionStarted(dimensions): dimensions.properties
        case let .transcriptionCompleted(dimensions, duration, wordCount, latency, output):
            dimensions.properties.merging([
                "duration_bucket": .string(duration.rawValue),
                "word_count_bucket": .string(wordCount.rawValue),
                "latency_bucket": .string(latency.rawValue),
                "output_method": .string(output.rawValue)
            ]) { current, _ in current }
        case let .transcriptionFailed(dimensions, error, stage):
            dimensions.properties.merging([
                "error_category": .string(error.rawValue),
                "pipeline_stage": .string(stage.rawValue)
            ]) { current, _ in current }
        case let .transcriptionCancelled(dimensions, duration):
            dimensions.properties.merging(["duration_bucket": .string(duration.rawValue)]) { current, _ in current }
        case let .polishCompleted(engine, provider, latency, preset):
            polishProperties(engine: engine, provider: provider, latency: latency, preset: preset)
        case let .polishFailed(engine, provider, latency, preset, error):
            polishProperties(engine: engine, provider: provider, latency: latency, preset: preset)
                .merging(["error_category": .string(error.rawValue)]) { current, _ in current }
        case let .correctionApplied(rulesMatched): ["rules_matched_bucket": .string(rulesMatched.rawValue)]
        case let .correctionRuleCreated(totalRules): ["total_rules_bucket": .string(totalRules.rawValue)]
        case let .profileActivated(profileCount, isDefault):
            ["profile_count_bucket": .string(profileCount.rawValue), "is_default": .boolean(isDefault)]
        case let .insightsViewed(surface): ["surface": .string(surface.rawValue)]
        case let .historyAction(action): ["action": .string(action.rawValue)]
        case let .voiceOutputUsed(engine, provider):
            ["engine_type": .string(engine.rawValue), "provider_type": .string(provider.rawValue)]
        case let .sendToMacCompleted(success, latency):
            ["success": .boolean(success), "latency_bucket": .string(latency.rawValue)]
        case let .modelDownloadCompleted(modelFamily, size, success):
            [
                "model_family": .string(modelFamily.rawValue),
                "size_bucket": .string(size.rawValue),
                "success": .boolean(success)
            ]
        case let .keyboardEnabledState(enabled): ["enabled": .boolean(enabled)]
        case let .providerConfigured(provider, method):
            ["provider_type": .string(provider.rawValue), "method": .string(method.rawValue)]
        case let .settingsChanged(setting, category):
            ["setting_id": .string(setting.rawValue), "category": .string(category.rawValue)]
        case let .errorDisplayed(error, surface):
            ["error_category": .string(error.rawValue), "surface": .string(surface.rawValue)]
        case let .analyticsOptIn(surface): ["surface": .string(surface.rawValue)]
        }
    }

    private func polishProperties(
        engine: AnalyticsEngineType,
        provider: AnalyticsProviderType,
        latency: AnalyticsLatencyBucket,
        preset: AnalyticsPolishPreset
    ) -> [String: AnalyticsPropertyValue] {
        [
            "engine_type": .string(engine.rawValue),
            "provider_type": .string(provider.rawValue),
            "latency_bucket": .string(latency.rawValue),
            "preset": .string(preset.rawValue)
        ]
    }
}

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

public actor ProductAnalyticsController {
    private let context: ProductAnalyticsContext
    private let sink: any ProductAnalyticsSink
    private let stateStore: any ProductAnalyticsStateStore
    private let forceDisabled: @Sendable () -> Bool
    private var consent: AnalyticsConsentState
    private var sinkIsClosed = false

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

    /// Applies a consent transition fail-closed: collection is only ever enabled after the new state is persisted,
    /// and every opt-out cleanup step is attempted even when an earlier step fails.
    public func setConsent(_ newConsent: AnalyticsConsentState) async throws {
        guard newConsent != .optedIn else {
            try stateStore.saveConsent(newConsent)
            guard !forceDisabled() else {
                consent = newConsent
                try await suspendCollection()
                return
            }
            try await sink.reopen()
            sinkIsClosed = false
            consent = newConsent
            return
        }
        consent = newConsent
        var firstFailure: Error?
        var shouldDeleteIdentity = true
        do {
            try stateStore.saveConsent(newConsent)
        } catch {
            firstFailure = error
            shouldDeleteIdentity = false
            do { try stateStore.resetState() } catch { firstFailure = firstFailure ?? error }
        }
        do {
            try await suspendCollection(deleteIdentity: shouldDeleteIdentity)
        } catch {
            firstFailure = firstFailure ?? error
        }
        if let firstFailure { throw firstFailure }
    }

    public func capture(_ event: ProductAnalyticsEvent) async throws {
        guard consent.permitsCollection else { return }
        guard !forceDisabled() else {
            try await suspendCollection()
            return
        }
        if sinkIsClosed {
            try await sink.reopen()
            sinkIsClosed = false
        }
        let distinctID = event.privacyClass == .pseudonymous ? try installationID() : nil
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

    private func suspendCollection(deleteIdentity: Bool = true) async throws {
        var firstFailure: Error?
        do { try await sink.purge() } catch { firstFailure = error }
        if deleteIdentity {
            do { try stateStore.deleteInstallationID() } catch { firstFailure = firstFailure ?? error }
        }
        await sink.close()
        sinkIsClosed = true
        if let firstFailure { throw firstFailure }
    }
}
