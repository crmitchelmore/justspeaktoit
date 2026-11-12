import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

struct SettingsView: View, AppSettingsBindingProviding, LocalModelRowPresenting {
  @EnvironmentObject var environment: AppEnvironment
  @EnvironmentObject var settings: AppSettings
  @EnvironmentObject var paidAccess: PaidAccessManager
  @EnvironmentObject var audioDevices: AudioInputDeviceManager
  @ObservedObject var updaterManager = UpdaterManager.shared
  @ObservedObject var localPostProcessingModels = LocalPostProcessingModelManager.shared
  @ObservedObject var cliInstaller = SpeakCLIInstaller.shared
  let tab: SettingsTab
  @Binding var sidebarSelection: SidebarItem?
  @State private var transcriptionProviders: [TranscriptionProviderMetadata] = []
  /// Voices only a keyed account lists — Mistral publishes no presets.
  @State var apiKeySearchText = ""
  @StateObject var apiKeyForm = APIKeyFormModel()
  @State var apiKeyStatusFilter: APIKeyStatusFilter = .all
  @State var apiKeySortOrder: APIKeySortOrder = .name
  @State private var didResolveAPIKeyStorage = false
  @State private var missingTranscriptionAPIKeyAlert: MissingLiveAPIKeyAlert?
  @State private var settingsSearchHighlightID: String?
  @State var showSystemPromptPreview = false
  @State var systemPromptPreview = ""
  @State var showingConfigTransfer = false
  @State var showingReleaseNotes = false
  /// Tracks the newest starter-preset download so a stale one cannot activate.
  @State var starterPresetActivationTask: Task<Void, Never>?

  typealias TranscriptionLocation = AppSettings.TranscriptionLocation
  typealias RemoteTranscriptionMode = AppSettings.RemoteTranscriptionMode
  typealias LocalTranscriptionSource = AppSettings.LocalTranscriptionSource

  let orderedLocalTranscriptionModes: [AppSettings.LocalTranscriptionMode] = {
    DistributionChannel.current.supportsInProcessLocalStreaming ? [.streaming, .batch] : [.batch]
  }()
  let orderedRemoteTranscriptionModes: [RemoteTranscriptionMode] = [.streaming, .batch]

  var body: some View {
    let density = settings.visualDensity
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: density.isCompact ? density.sectionSpacing : 28) {
          SettingsOverviewHeader(isOpenRouterKeyStored: isOpenRouterKeyStored)
          tabContent
        }
        .padding(density.pagePadding)
        .frame(maxWidth: 1100, alignment: .center)
      }
      .environment(\.settingsSearchHighlightID, settingsSearchHighlightID)
      .task(id: environment.settingsSearchTarget) {
        await revealSettingsSearchTarget(using: proxy)
      }
      .task(id: settingsSearchHighlightID) {
        guard settingsSearchHighlightID != nil else { return }
        try? await Task.sleep(for: .seconds(2.5))
        guard !Task.isCancelled else { return }
        settingsSearchHighlightID = nil
      }
    }
    .background(
      LinearGradient(
        colors: [Color.brandAccentWarm.opacity(0.08), .clear], startPoint: .top, endPoint: .center))
    .task {
      transcriptionProviders = await TranscriptionProviderRegistry.shared.allProviders()
      keytermSync.syncFromPronunciation()
      await resolveAPIKeyStorage()
    }
    .onChange(of: settings.liveTranscriptionModel) { _, newValue in
      let newIsAssembly = newValue.localizedCaseInsensitiveContains("assemblyai")
      if newIsAssembly {
        settings.postProcessingEnabled = false
        keytermSync.syncFromPronunciation()
      }
    }
    .onChange(of: settings.assemblyAIKeyterms) { _, _ in
      keytermSync.syncIgnored()
    }
    .onChange(of: settings.ttsPronunciationDictionary) { _, _ in
      keytermSync.syncFromPronunciation()
    }
    .alert(
      missingTranscriptionAPIKeyAlert?.title ?? "API key required",
      isPresented: Binding(
        get: { missingTranscriptionAPIKeyAlert != nil },
        set: { if !$0 { missingTranscriptionAPIKeyAlert = nil } }
      ),
      presenting: missingTranscriptionAPIKeyAlert
    ) { alert in
      Button("Add API Key") {
        // A provider whose single key also powers voice output has no
        // transcription card; its combined card lives in the TTS list.
        let sharedCredentialID = TTSProvider.allCases
          .first { $0.sharesTranscriptionCredential && $0.id == alert.provider.id }?
          .id
        environment.apiKeysScrollTarget = sharedCredentialID.map { "tts-\($0)" }
          ?? "transcription-\(alert.provider.id)"
        sidebarSelection = .settings(.apiKeys)
        missingTranscriptionAPIKeyAlert = nil
      }
      if let url = alert.keyPageURL {
        Button("Get API Key") {
          NSWorkspace.shared.open(url)
          missingTranscriptionAPIKeyAlert = nil
        }
      }
      Button("Cancel", role: .cancel) {
        missingTranscriptionAPIKeyAlert = nil
      }
    } message: { alert in
      Text(alert.message)
    }
    .onReceive(environment.pronunciationManager.$entries) { _ in
      keytermSync.syncFromPronunciation()
    }
  }
}

extension SettingsView {
  var isOpenRouterKeyStored: Bool {
    isAPIKeyStored(APIKeyFormModel.openRouterKeyIdentifier)
  }

  func isAPIKeyStored(_ identifier: String) -> Bool {
    didResolveAPIKeyStorage && settings.trackedAPIKeyIdentifiers.contains(identifier)
  }

  private func resolveAPIKeyStorage() async {
    let retryDelays: [Duration] = [
      .milliseconds(250),
      .milliseconds(500),
      .seconds(1),
      .seconds(2),
      .seconds(5)
    ]
    var retryIndex = 0

    while !Task.isCancelled {
      if await environment.secureStorage.preloadTrackedSecrets() {
        didResolveAPIKeyStorage = true
        return
      }

      let retryDelay = retryDelays[min(retryIndex, retryDelays.count - 1)]
      retryIndex = min(retryIndex + 1, retryDelays.count - 1)
      do {
        try await Task.sleep(for: retryDelay)
      } catch {
        return
      }
    }
  }

  var allMacAPIKeyItems: [MacAPIKeyItem] {
    MacAPIKeyItem.all(transcriptionProviders: transcriptionProviders, form: apiKeyForm, isStored: isAPIKeyStored)
  }

  var isCloudPostProcessingModelSelected: Bool {
    !PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel)
  }

  var systemGeneratedPartsHelpText: String {
    if isCloudPostProcessingModelSelected {
      return "Choose the language and lexicon context layered into the canonical OpenRouter cleanup policy."
    }
    if PostProcessingManager.isBuiltInLocalPostProcessingModel(settings.postProcessingModel) {
      return """
      These prompt parts apply when you choose a downloaded local LLM model. \
      The built-in rules cleaner does not use prompts.
      """
    }
    return "Choose the language and lexicon context layered into the canonical local cleanup policy."
  }

  @MainActor
  func remoteTranscriptionModelBinding(
    _ keyPath: ReferenceWritableKeyPath<AppSettings, String>,
    options: [ModelCatalog.Option]
  ) -> Binding<String> {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: { newValue in
        settings[keyPath: keyPath] = newValue
        Task {
          await presentMissingTranscriptionAPIKeyAlertIfNeeded(
            for: newValue,
            keyPath: keyPath,
            options: options
          )
        }
      }
    )
  }

  @MainActor
  private func presentMissingTranscriptionAPIKeyAlertIfNeeded(
    for model: String,
    keyPath: ReferenceWritableKeyPath<AppSettings, String>,
    options: [ModelCatalog.Option]
  ) async {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != ModelCatalog.customOptionID else { return }
    let registry = TranscriptionProviderRegistry.shared
    guard await registry.requiresAPIKey(for: trimmed),
          let provider = await registry.provider(forModel: trimmed) else {
      return
    }
    let hasAPIKey = await environment.secureStorage.hasSecret(
      identifier: provider.metadata.apiKeyIdentifier
    )
    guard !hasAPIKey else {
      return
    }

    let modelName = options.first {
      $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
    }?.displayName ?? ModelCatalog.friendlyName(for: trimmed)

    let current = settings[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
    guard current.caseInsensitiveCompare(trimmed) == .orderedSame else { return }

    missingTranscriptionAPIKeyAlert = MissingLiveAPIKeyAlert(
      provider: provider.metadata,
      modelDisplayName: modelName
    )
  }

  @ViewBuilder
  private var tabContent: some View {
    switch tab {
    case .general:
      generalSettings
    case .transcription:
      transcriptionSettings
    case .postProcessing:
      postProcessingSettings
    case .profiles:
      profilesSettings
    case .voiceOutput:
      VoiceOutputSettingsSection()
    case .pronunciation:
      pronunciationSettings
    case .apiKeys:
      apiKeySettings
    case .shortcuts:
      keyboardSettings
    case .permissions:
      permissionsSettings
    case .compareModels:
      CompareModelsView()
    case .dataMigration:
      DataMigrationView()
    case .about:
      aboutSettings
    }
  }

  /// Scrolls to and briefly highlights the card settings search selected.
  /// Section-root entries only select the page, which MainView already did.
  /// The target is cleared last: clearing it restarts this task.
  private func revealSettingsSearchTarget(using proxy: ScrollViewProxy) async {
    guard let target = environment.settingsSearchTarget else { return }
    if target.hasPrefix(MacSettingsSearch.apiKeyEntryPrefix) {
      environment.apiKeysScrollTarget = String(target.dropFirst(MacSettingsSearch.apiKeyEntryPrefix.count))
      settingsSearchHighlightID = target
    } else if SettingsSearchSection(rawValue: target) == nil {
      // Let the newly selected page lay out before scrolling to its card.
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      withAnimation { proxy.scrollTo(target, anchor: .top) }
      settingsSearchHighlightID = target
    }
    environment.settingsSearchTarget = nil
  }

  init(tab: SettingsTab = .general, sidebarSelection: Binding<SidebarItem?>) {
    self.tab = tab
    _sidebarSelection = sidebarSelection
  }

  var cloudPostProcessingModelBinding: Binding<String> {
    Binding(
      get: {
        if PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel) {
          return ModelCatalog.postProcessing.first {
            !PostProcessingManager.isLocalPostProcessingModel($0.id)
          }?.id ?? settings.postProcessingModel
        }
        guard cloudPostProcessingOptions.contains(where: { $0.id == settings.postProcessingModel }) else {
          return cloudPostProcessingOptions.first?.id ?? settings.postProcessingModel
        }
        return settings.postProcessingModel
      },
      set: { model in
        settings.postProcessingModel = model
      }
    )
  }

  private var keytermSync: AssemblyAIPronunciationKeytermSync {
    AssemblyAIPronunciationKeytermSync(settings: settings, pronunciation: environment.pronunciationManager)
  }

  private var pronunciationSettings: some View {
    PronunciationDictionaryView()
      .environmentObject(environment.pronunciationManager)
  }

  @MainActor
  func generateSystemPromptPreview() {
    self.systemPromptPreview = CleanupPromptPreview.text(
      model: settings.postProcessingModel,
      outputLanguage: settings.postProcessingOutputLanguage,
      lexiconRuleCount: environment.personalLexicon.rules.count,
      includeLexiconDirectives: settings.postProcessingIncludeLexiconDirectives,
      includeContextTags: settings.postProcessingIncludeContextTags
    )
  }
}

// @Implement: This view manages the app settings class, grouped into logical setting sections.
// - API key management: save keys to key vault and validate them with an API call.
// - General configuration: appearance, caches, audio files, text output, and status bar behaviour.
// - Transcription configuration: live/batch mode, provider, selected model, and model configuration.
// - Post-processing configuration. System prompt and temperature, model selection, enabled or disabled.
// - Hotkey management and configuration: Allow selection of a hotkey, defaulting to the fn key.
// - Permission management: Let users inspect and validate required permissions.
// And then any other sections you think are relevant. This should be presented in a concise but user-friendly format.
