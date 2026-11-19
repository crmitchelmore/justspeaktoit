import AppKit
import Combine
import SpeakCore
import SpeakHotKeys
import SwiftUI

// MARK: - Onboarding State

@MainActor
final class OnboardingState: ObservableObject {
    @Published var currentStep: OnboardingStep = .welcome
    @Published var selectedProvider: OnboardingProvider = .deepgram
    @Published var apiKey = ""
    @Published var isValidating = false
    @Published var validationError: String?
    @Published private(set) var permissionsGranted: Set<PermissionType> = []
    private var permissionsObserver: AnyCancellable?
    @Published var selectedHotKey: HotKey = .fnKey
    @Published var hotKeyWasChosen = false
    @Published var transcriptionLocation: AppSettings.TranscriptionLocation = .remote
    @Published var configuredLocalPreset: LocalTranscriptionStarterPreset?
    @Published var isConfiguringLocalModel = false
    @Published private(set) var isCompletingRemoteSetup = false
    private var localConfigurationID: UUID?

    // Test recording state
    @Published var isTestRecording = false
    @Published var testRecordingText: String?
    @Published var testRecordingError: String?

    let permissionsManager: PermissionsManager
    let secureStorage: SecureAppStorage
    let settings: AppSettings
    let hotKeyManager: HotKeyManager
    let audioFileManager: AudioFileManager
    let transcriptionManager: TranscriptionManager

    init(
        permissionsManager: PermissionsManager,
        secureStorage: SecureAppStorage,
        settings: AppSettings,
        hotKeyManager: HotKeyManager,
        audioFileManager: AudioFileManager,
        transcriptionManager: TranscriptionManager
    ) {
        self.permissionsManager = permissionsManager
        self.secureStorage = secureStorage
        self.settings = settings
        self.hotKeyManager = hotKeyManager
        self.audioFileManager = audioFileManager
        self.transcriptionManager = transcriptionManager
        self.selectedHotKey = settings.selectedHotKey
        self.hotKeyWasChosen = settings.hasConfiguredGlobalHotKey
        // Consume the emitted snapshot: @Published emits before the manager's
        // stored dictionary changes. Guide polling and activation refreshes must
        // update onboarding too, without a separate confirmation button.
        permissionsObserver = permissionsManager.$statuses
            .map { statuses in
                Set(PermissionType.availablePermissions(for: DistributionChannel.current)
                    .filter { statuses[$0]?.isGranted == true })
            }
            .removeDuplicates()
            .sink { [weak self] granted in self?.permissionsGranted = granted }
        refreshPermissions()
    }

    func refreshPermissions() {
        // Cached statuses go stale when the user toggles a permission in System
        // Settings (the OS never notifies us); the subscription above publishes the result.
        permissionsManager.refreshAll()
    }

    var allPermissionsGranted: Bool {
        permissionsGranted.contains(.microphone) &&
        (!DistributionChannel.current.supportsAccessibilityTextInsertion
          || permissionsGranted.contains(.accessibility))
    }

    func validateAPIKey() async -> Bool {
        guard !apiKey.isEmpty else {
            validationError = "Please enter an API key"
            return false
        }

        isValidating = true
        validationError = nil

        let result = await validationResult(for: apiKey)
        isValidating = false

        switch result.outcome {
        case .success:
            return true
        case .failure(let message):
            validationError = message
            return false
        }
    }

    /// Validates the entered key with whichever component owns the provider's
    /// credential, mirroring how Settings validates the same keys.
    ///
    /// Transcription providers go through `TranscriptionProviderRegistry`.
    /// OpenRouter is an LLM provider rather than a transcription provider, so it
    /// has no registry entry; Settings validates it through `OpenRouterAPIClient`
    /// and onboarding does the same.
    private func validationResult(for key: String) async -> APIKeyValidationResult {
        if selectedProvider == .openrouter {
            return await OpenRouterAPIClient(secureStorage: secureStorage).validateAPIKey(key)
        }

        guard let provider = await TranscriptionProviderRegistry.shared
            .provider(withID: selectedProvider.rawValue)
        else {
            return .failure(message: "Provider not found")
        }
        return await provider.validateAPIKey(key)
    }

    func saveAPIKey() async throws {
        let identifier = selectedProvider.keychainIdentifier
        try await secureStorage.storeSecret(apiKey, identifier: identifier)
        // Register the key identifier so it shows up in settings
        settings.registerAPIKeyIdentifier(identifier)
    }

    func skipAPIKeySetup() {
        apiKey = ""
        validationError = nil
        Self.disableUnavailablePostProcessing(in: settings)
    }

    func configureLocalModel(
        _ preset: LocalTranscriptionStarterPreset,
        prepare: () async -> LocalModelManager.InstallState
    ) async {
        guard !isConfiguringLocalModel else { return }
        let configurationID = UUID()
        localConfigurationID = configurationID
        isConfiguringLocalModel = true
        validationError = nil
        defer {
            if localConfigurationID == configurationID {
                isConfiguringLocalModel = false
                localConfigurationID = nil
            }
        }
        let installState = await prepare()
        guard !Task.isCancelled, localConfigurationID == configurationID else { return }
        switch installState {
        case .installed:
            configuredLocalPreset = preset
        case .failed(let message):
            validationError = "Could not configure \(preset.displayName): \(message). Try downloading again."
        case .notInstalled, .installing:
            validationError = "\(preset.displayName) is not ready yet. Finish downloading before continuing."
        }
    }

    func leaveLocalModelSetup() {
        localConfigurationID = nil
        isConfiguringLocalModel = false
    }

    @discardableResult
    func completeLocalModelSetup() -> Bool {
        guard transcriptionLocation == .local, !isConfiguringLocalModel,
              let preset = configuredLocalPreset else {
            validationError = "Choose and download a local model before continuing."
            return false
        }
        preset.activate(in: settings)
        if !PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel) {
            settings.postProcessingEnabled = false
        }
        return true
    }

    func completeRemoteModelSetup() {
        // Preserve an existing remote model, but use the new provider when the
        // live slot is still Apple's default. Commit routing only after awaits.
        if let liveModel = selectedProvider.defaultLiveTranscriptionModel,
           AppleLocalModels.isAppleSpeechModel(settings.liveTranscriptionModel) {
            settings.liveTranscriptionModel = liveModel
            settings.postProcessingEnabled = false
        }
        settings.selectTranscriptionLocation(.remote)
    }

    func completeRemoteSetup(
        validate: () async -> Bool,
        save: () async throws -> Void
    ) async -> Bool {
        guard transcriptionLocation == .remote, !isCompletingRemoteSetup else { return false }
        isCompletingRemoteSetup = true
        defer { isCompletingRemoteSetup = false }
        let provider = selectedProvider
        let key = apiKey
        let step = currentStep
        let matchesSubmission = {
            self.transcriptionLocation == .remote && self.selectedProvider == provider
                && self.apiKey == key && self.currentStep == step && !Task.isCancelled
        }
        guard await validate(), matchesSubmission() else { return false }
        do {
            try await save()
        } catch {
            if matchesSubmission() {
                validationError = "Failed to save: \(error.localizedDescription)"
            }
            return false
        }
        guard matchesSubmission() else { return false }
        completeRemoteModelSetup()
        return true
    }

    static func disableUnavailablePostProcessing(in settings: AppSettings) {
        let availability = ModelCredentialResolver.availability(
            for: settings.postProcessingModel,
            purpose: .postProcessing,
            storedAPIKeyIdentifiers: settings.trackedAPIKeyIdentifiers
        )
        if case .missing = availability {
            settings.postProcessingEnabled = false
        }
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case hotkey
    case apiKey
    case testRecording
    case complete

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .hotkey: return "Hotkey"
        case .apiKey: return "API Key"
        case .testRecording: return "Test"
        case .complete: return "Ready!"
        }
    }
}
