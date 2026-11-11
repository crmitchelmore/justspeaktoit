import SpeakCore
import SpeakDesktop

package enum DesktopHostPreferenceArchive {
    package static func project<Platform: DesktopHostPlatform>(
        _ settings: DesktopHostController<Platform>.Settings, categories: Set<DataMigrationCategory>,
        validateJSON: ((DataMigrationRecord) throws -> Void)? = nil
    ) throws -> DataMigrationPreferenceProjection {
        var native = Platform.archiveNativePreferences(
            textOutput: settings.textOutput, hotKey: settings.hotKey, voiceOutput: settings.voiceOutput
        )
        addSharedAuthorities(settings, to: &native)
        var values = settings.configuration?.values ?? [:]
        for key in native.suppressedKeys.union(native.values.keys).sorted()
            where values.removeValue(forKey: key) != nil {
            native.notices.append(.init(path: "configuration.\(key)", reason: .shadowed))
        }
        values.merge(native.values) { _, current in current }
        var result = try DataMigrationPreferenceProjection.project(
            values, categories: categories, authoritativeKeys: Set(native.values.keys), validateJSON: validateJSON
        )
        result.notices += native.notices
        result.notices += settings.archiveUnknownKeys.sorted().map { .init(path: $0, reason: .unknownPreference) }
        return result
    }

    private static func addSharedAuthorities<Platform: DesktopHostPlatform>(
        _ settings: DesktopHostController<Platform>.Settings, to native: inout DesktopHostNativePreferenceProjection
    ) {
        if let value = settings.archiveBatchModel { native.set(.batchTranscriptionModel, .string(value)) }
        if let value = settings.archiveLiveModel { native.set(.liveTranscriptionModel, .string(value)) }
        if let value = settings.archiveLocalModel { native.set(.localTranscriptionModel, .string(value)) }
        if let value = settings.archiveLocalLiveModel { native.set(.localStreamingModelSource, .string(value)) }
        if let model = settings.archiveModel { addActiveModel(model, to: &native) }
        addAppearanceAndServices(settings, to: &native)
        if let polish = settings.postProcessing { addPostProcessing(polish, to: &native) }
        if settings.microphoneDeviceID != nil { native.nativeOnly("microphoneDeviceID") }
        if settings.localUseGPU != nil { native.nativeOnly("localUseGPU") }
        if settings.azureSpeechResourceEndpoint != nil { native.nativeOnly("azureSpeechResourceEndpoint") }
    }

    private static func addAppearanceAndServices<Platform: DesktopHostPlatform>(
        _ settings: DesktopHostController<Platform>.Settings, to native: inout DesktopHostNativePreferenceProjection
    ) {
        if let value = settings.appearance {
            let name: String
            switch value {
            case .system: name = "system"
            case .light: name = "light"
            case .dark: name = "dark"
            }
            native.set(.appearance, .string(name))
        }
        if let value = settings.runAtLogin { native.set(.runAtLogin, .bool(value)) }
        if let value = settings.automationEnabled { native.set(.enableAutomationServer, .bool(value)) }
        if settings.automationLocalConsent != nil { native.nativeOnly("automationLocalConsent") }
        if settings.livePolishApproved != nil { native.nativeOnly("livePolishApproved") }
    }

    private static func addActiveModel(_ model: String, to native: inout DesktopHostNativePreferenceProjection) {
        if case .downloadedLocal(engine: .streaming) = ModelRouting.family(for: model) {
            native.set(.transcriptionMode, .string("localModel"))
            native.set(.localTranscriptionMode, .string("streaming"))
            native.set(.localStreamingModelSource, .string(model))
        } else if case .downloadedLocal = ModelRouting.family(for: model) {
            native.set(.transcriptionMode, .string("localModel"))
            native.set(.localTranscriptionMode, .string("batch"))
            native.set(.localTranscriptionModel, .string(model))
        } else if DesktopLiveTranscription.route(forID: model) != nil {
            native.set(.transcriptionMode, .string("liveNative"))
            native.set(.liveTranscriptionModel, .string(model))
        } else if DesktopTranscription.provider(for: model) != nil {
            native.set(.transcriptionMode, .string("batchRemote"))
            native.set(.batchTranscriptionModel, .string(model))
        } else {
            native.nativeOnly("model", suppressing: .transcriptionMode)
        }
    }

    private static func addPostProcessing(
        _ polish: DesktopPostProcessing.Options, to native: inout DesktopHostNativePreferenceProjection
    ) {
        native.set(.postProcessingEnabled, .bool(polish.mode != .disabled))
        native.set(.postProcessingModel, .string(polish.modelIdentifier))
        native.set(.postProcessingTemperature, .double(polish.temperature))
        native.set(.postProcessingIncludeLexiconDirectives, .bool(polish.includeLexiconDirectives))
        native.set(.postProcessingIncludeContextTags, .bool(polish.includeContextTags))
        native.set(.postProcessingStreamingEnabled, .bool(polish.streamingEnabled))
        if let language = polish.outputLanguage {
            native.set(.postProcessingOutputLanguage, .string(language))
        } else {
            native.suppressedKeys.insert(ApplicationPreferenceKey.postProcessingOutputLanguage.rawValue)
        }
        if polish.customPrompt != nil { native.nativeOnly("postProcessing.customPrompt") }
    }
}

extension DesktopHostController {
    package func preferenceArchiveProjection(
        categories: Set<DataMigrationCategory>,
        validateJSON: ((DataMigrationRecord) throws -> Void)? = nil
    ) throws -> DataMigrationPreferenceProjection {
        try DesktopHostPreferenceArchive.project(settings, categories: categories, validateJSON: validateJSON)
    }
}
