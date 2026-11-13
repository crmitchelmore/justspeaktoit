import SpeakCore

/// The cached live controllers and the routing from a model identifier to the
/// one that streams it. This is the single place live controllers are
/// constructed: `SwitchingLiveTranscriber` builds a fresh set at init and on
/// every reset, so the two paths cannot drift.
@MainActor
struct LiveControllerSet {
    let native: NativeOSXLiveTranscriber
    let speechAnalyzer: AppleSpeechAnalyzerLiveController
    let openAIRealtime: OpenAIRealtimeLiveController
    let sharedClient: SharedClientLiveController
    let fluidAudio: FluidAudioParakeetLiveController
    let whisperKit: WhisperKitLiveController
    #if !APP_STORE
        let sherpaOnnx: SherpaOnnxLiveController
    #endif
    let unsupportedLocalLive: UnsupportedLocalLiveTranscriber

    init(
        appSettings: AppSettings,
        permissionsManager: PermissionsManager,
        audioDeviceManager: AudioInputDeviceManager,
        secureStorage: SecureAppStorage
    ) {
        native = NativeOSXLiveTranscriber(
            permissionsManager: permissionsManager,
            appSettings: appSettings,
            audioDeviceManager: audioDeviceManager
        )
        speechAnalyzer = AppleSpeechAnalyzerLiveController(
            permissionsManager: permissionsManager,
            appSettings: appSettings,
            audioDeviceManager: audioDeviceManager
        )
        openAIRealtime = OpenAIRealtimeLiveController(
            appSettings: appSettings,
            permissionsManager: permissionsManager,
            audioDeviceManager: audioDeviceManager,
            secureStorage: secureStorage
        )
        sharedClient = SharedClientLiveController(
            permissionsManager: permissionsManager,
            audioDeviceManager: audioDeviceManager,
            secureStorage: secureStorage,
            appSettings: appSettings
        )
        fluidAudio = FluidAudioParakeetLiveController(
            appSettings: appSettings,
            permissionsManager: permissionsManager,
            audioDeviceManager: audioDeviceManager,
            modelManager: FluidAudioModelManager.shared
        )
        whisperKit = WhisperKitLiveController(
            permissionsManager: permissionsManager,
            audioDeviceManager: audioDeviceManager,
            modelManager: LocalModelManager.shared
        )
        #if !APP_STORE
            sherpaOnnx = SherpaOnnxLiveController(
                appSettings: appSettings,
                permissionsManager: permissionsManager,
                audioDeviceManager: audioDeviceManager,
                runtimeManager: SherpaOnnxRuntimeManager.shared
            )
        #endif
        unsupportedLocalLive = UnsupportedLocalLiveTranscriber()
    }

    func controller(for model: String) -> any LiveTranscriptionController {
        if AppleLocalModels.isSpeechAnalyzerModel(model) {
            return speechAnalyzer
        }
        if let controller = cloudController(for: model) { return controller }
        if FluidAudioParakeetModel.matches(model) { return fluidAudio }
        if WhisperKitStreamingModel.matches(model) { return whisperKit }
        #if !APP_STORE
            if model.hasPrefix("local/streaming/") { return sherpaOnnx }
        #else
            if model.hasPrefix("local/streaming/") { return unsupportedLocalLive }
        #endif
        if ModelRouting.family(for: model).isDownloadedLocal { return unsupportedLocalLive }
        return native
    }

    /// The controller that owns a cloud live model, chosen by the shared
    /// `LiveTranscriptionProviderID` so a newly catalogued provider fails to
    /// compile here until the Mac decides how it streams. Every provider runs on
    /// the shared SpeakCore client except OpenAI, whose Apple hosts sequence the
    /// Realtime commit themselves.
    private func cloudController(for model: String) -> (any LiveTranscriptionController)? {
        guard let provider = Self.cloudProvider(for: model) else { return nil }
        switch provider {
        case .apple: return nil
        // OpenAI's only live transcription transport is the Realtime WebSocket
        // API, so any openai/* live model is handled by the realtime controller.
        case .openai: return openAIRealtime
        case .assemblyai, .cartesia, .deepgram, .elevenlabs, .gladia, .google, .xai, .azure, .alibaba, .meta,
             .speechmatics, .revai, .mistral, .reson8, .soniox, .modulate:
            return sharedClient
        }
    }

    /// The cloud provider that owns `model`'s exact identifier prefix, or `nil`
    /// for on-device and unrecognised identifiers. Matching is case-sensitive and
    /// untrimmed, and only Gemini's live catalogue model is claimed under
    /// `google/`, so an unknown identifier never reaches a cloud controller it
    /// did not reach before.
    static func cloudProvider(for model: String) -> LiveTranscriptionProviderID? {
        guard let slash = model.firstIndex(of: "/"),
              let provider = LiveTranscriptionProviderID(rawValue: String(model[..<slash])),
              provider != .apple
        else { return nil }
        if provider == .google, !model.hasPrefix(GeminiTranscribeModels.liveCatalogID) { return nil }
        return provider
    }

    var all: [any LiveTranscriptionController] {
        var controllers: [any LiveTranscriptionController] = [
            native,
            speechAnalyzer,
            openAIRealtime,
            sharedClient,
            whisperKit,
            fluidAudio
        ]
        #if !APP_STORE
            controllers.append(sherpaOnnx)
        #endif
        controllers.append(unsupportedLocalLive)
        return controllers
    }
}
