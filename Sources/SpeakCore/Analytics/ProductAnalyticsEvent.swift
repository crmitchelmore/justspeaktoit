import Foundation

// The privacy contract spans ProductAnalyticsTaxonomy (closed property values),
// ProductAnalyticsEvent (what each event may carry), ProductAnalyticsPayload
// (the context boundary) and ProductAnalyticsController (consent and identity).

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
