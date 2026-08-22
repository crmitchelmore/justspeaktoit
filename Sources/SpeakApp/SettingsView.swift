import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

// swiftlint:disable file_length type_body_length

struct MacAPIKeyItem: Identifiable {
  enum Source {
    case openRouter
    case transcription(TranscriptionProviderMetadata)
    case textToSpeech(TTSProvider)
  }

  let entry: APIKeyListEntry
  let source: Source
  var id: String { entry.id }
}

struct SettingsView: View {
  @EnvironmentObject var environment: AppEnvironment
  @EnvironmentObject var settings: AppSettings
  @EnvironmentObject var paidAccess: PaidAccessManager
  @EnvironmentObject var audioDevices: AudioInputDeviceManager
  @ObservedObject var updaterManager = UpdaterManager.shared
  @ObservedObject var localModels = LocalModelManager.shared
  @ObservedObject var fluidAudioModels = FluidAudioModelManager.shared
  #if !APP_STORE
  @ObservedObject var sherpaRuntime = SherpaOnnxRuntimeManager.shared
  #endif
  @ObservedObject var localPostProcessingModels = LocalPostProcessingModelManager.shared
  let tab: SettingsTab
  @Binding var sidebarSelection: SidebarItem?
  @State var newAPIKeyValue: String = ""
  @State var apiKeyValidationState: ValidationViewState = .idle
  @State var isDeletingRecordings: Bool = false
  @State private var transcriptionProviders: [TranscriptionProviderMetadata] = []
  @State var providerAPIKeys: [String: String] = [:]
  @State var providerValidationStates: [String: ValidationViewState] = [:]
  @State var ttsProviderAPIKeys: [String: String] = [:]
  @State var ttsProviderValidationStates: [String: ValidationViewState] = [:]
  @State var apiKeySearchText = ""
  @State var apiKeyStatusFilter: APIKeyStatusFilter = .all
  @State var apiKeySortOrder: APIKeySortOrder = .name
  @State private var didResolveAPIKeyStorage = false
  @State private var missingTranscriptionAPIKeyAlert: MissingLiveAPIKeyAlert?
  @State var showSystemPromptPreview = false
  @State var systemPromptPreview = ""
  @State var showingConfigTransfer = false
  @State var showingReleaseNotes = false
  @State private var soundPreviewPlayer: RecordingSoundPlayer?
  @State var huggingFaceRepoID: String = "argmaxinc/whisperkit-coreml"
  @State var huggingFaceModelName: String = "tiny"
  @State var huggingFaceImportError: String?
  @State var isLocalTranscriptionAdvancedExpanded = false
  /// Tracks the newest starter-preset download so a stale one cannot activate.
  @State var starterPresetActivationTask: Task<Void, Never>?
  #if !APP_STORE
  @State var streamingHuggingFaceRepoID: String =
    "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26"
  @State var streamingHuggingFaceModelName: String = "streaming-zipformer-en-2023-06-26"
  @State var selectedRecommendedStreamingSourceID: String =
    LocalModelManager.recommendedStreamingModelSources.first?.id ?? ""
  @State var streamingHuggingFaceImportError: String?
  #endif
  #if !APP_STORE
  @State var localPostProcessingRepoID: String = "unsloth/Qwen3-0.6B-GGUF"
  @State var localPostProcessingFilename: String = "Qwen3-0.6B-Q4_K_M.gguf"
  @State var localPostProcessingSizeMB: String = "450"
  @State var localPostProcessingImportError: String?
  #endif
  let openRouterKeyIdentifier = "openrouter.apiKey"

  typealias TranscriptionLocation = AppSettings.TranscriptionLocation
  typealias RemoteTranscriptionMode = AppSettings.RemoteTranscriptionMode
  typealias LocalTranscriptionSource = AppSettings.LocalTranscriptionSource

  enum StarterPresetInstallState: Equatable {
    case notInstalled
    case installing
    case installed
    case failed(String)
  }

  let orderedLocalTranscriptionModes: [AppSettings.LocalTranscriptionMode] = {
    DistributionChannel.current.supportsInProcessLocalStreaming ? [.streaming, .batch] : [.batch]
  }()
  let orderedRemoteTranscriptionModes: [RemoteTranscriptionMode] = [.streaming, .batch]

  private enum PostProcessingLocation: String, CaseIterable, Identifiable {
    case remote
    case local

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .remote: return "Remote"
      case .local: return "Local"
      }
    }
  }

  enum ValidationViewState {
    case idle
    case validating
    case finished(APIKeyValidationResult)
  }

  struct APIKeyCardConfiguration {
    let title: String
    let tint: Color
    let statusIcon: String
    let statusTint: Color
    let isStored: Bool
    let descriptionText: String
    let keyFieldLabel: String
    let keyBinding: Binding<String>
    let onSave: () -> Void
    let onValidate: (() -> Void)?
    let onRemove: (() -> Void)?
    let isSaveDisabled: Bool
    let isValidateDisabled: Bool
    let isRemoveDisabled: Bool
    let validationState: ValidationViewState
    let saveButtonTitle: String
    let saveTooltip: String
    let validateButtonTitle: String
    let validateTooltip: String
    let removeButtonTitle: String
    let removeTooltip: String
    let link: URL?
    let linkLabel: String?
    let statusLabel: String
  }

  var isOpenRouterKeyStored: Bool {
    isAPIKeyStored(openRouterKeyIdentifier)
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

  var isCloudPostProcessingModelSelected: Bool {
    !PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel)
  }

  var isValidatingKey: Bool {
    if case .validating = apiKeyValidationState { return true }
    return false
  }

  var allMacAPIKeyItems: [MacAPIKeyItem] {
    var items = [
      MacAPIKeyItem(
        entry: APIKeyListEntry(
          id: "general-openrouter",
          title: "OpenRouter",
          category: "Post-processing",
          isStored: isOpenRouterKeyStored
        ),
        source: .openRouter
      )
    ]
    // ElevenLabs and Soniox each use one key for transcription and voice
    // output; their combined card is contributed by the TTS list below.
    let sharedCredentialProviderIDs = Set(
      TTSProvider.allCases.filter(\.sharesTranscriptionCredential).map(\.id)
    )
    items += transcriptionProviders
      .filter { !sharedCredentialProviderIDs.contains($0.id) }
      .map { provider in
        MacAPIKeyItem(
          entry: APIKeyListEntry(
            id: "transcription-\(provider.id)",
            title: provider.displayName,
            category: "Transcription",
            isStored: isAPIKeyStored(provider.apiKeyIdentifier)
          ),
          source: .transcription(provider)
        )
      }
    items += [TTSProvider.elevenlabs, .openai, .azure, .deepgram, .soniox].map { provider in
      let isShared = provider.sharesTranscriptionCredential
      return MacAPIKeyItem(
        entry: APIKeyListEntry(
          id: "tts-\(provider.id)",
          title: provider == .elevenlabs ? "ElevenLabs" : provider.displayName,
          category: isShared ? "Transcription & Voice Output" : "Voice Output",
          isStored: isAPIKeyStored(provider.apiKeyIdentifier)
        ),
        source: .textToSpeech(provider)
      )
    }
    return items
  }

  var visibleMacAPIKeyItems: [MacAPIKeyItem] {
    let orderedEntries = APIKeyListQuery.apply(
      to: allMacAPIKeyItems.map(\.entry),
      searchText: apiKeySearchText,
      status: apiKeyStatusFilter,
      sortOrder: apiKeySortOrder
    )
    let itemsByID = Dictionary(uniqueKeysWithValues: allMacAPIKeyItems.map { ($0.id, $0) })
    return orderedEntries.compactMap { itemsByID[$0.id] }
  }

  private var overviewPostProcessingValue: String {
    if settings.isActiveAssemblyAILiveModel {
      return "Keyterms only"
    }
    guard settings.postProcessingEnabled, settings.speedMode == .instant else {
      return "Disabled"
    }
    return PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel)
      ? "Local"
      : "Remote"
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

  @ViewBuilder
  private var overviewHeader: some View {
    if settings.visualDensity.isCompact {
      compactOverviewHeader
    } else {
      normalOverviewHeader
    }
  }

  private var compactOverviewHeader: some View {
    HStack(spacing: settings.visualDensity.groupSpacing) {
      Label("Settings", systemImage: "slider.horizontal.3")
        .font(.subheadline.bold())
        .lineLimit(1)

      Spacer(minLength: 4)

      compactOverviewMetric(
        title: "Mode",
        value: overviewModeValue,
        systemImage: "waveform"
      )
      compactOverviewMetric(
        title: settings.isActiveAssemblyAILiveModel ? "Pre-processing" : "Post-processing",
        value: overviewPostProcessingValue,
        systemImage: "wand.and.stars"
      )
      compactOverviewMetric(
        title: "Output",
        value: settings.textOutputMethod.displayName,
        systemImage: "text.alignleft"
      )
      compactOverviewMetric(
        title: "OpenRouter Key",
        value: isOpenRouterKeyStored ? "Stored" : "Missing",
        systemImage: isOpenRouterKeyStored ? "checkmark.seal.fill" : "key.fill"
      )
    }
    .padding(settings.visualDensity.cardPadding)
    .foregroundStyle(.white)
    .background(
      LinearGradient(
        colors: [Color.orange, Color.orange.opacity(0.72)],
        startPoint: .leading,
        endPoint: .trailing
      ),
      in: RoundedRectangle(
        cornerRadius: settings.visualDensity.cardCornerRadius,
        style: .continuous
      )
    )
  }

  private func compactOverviewMetric(
    title: String,
    value: String,
    systemImage: String
  ) -> some View {
    Label(value, systemImage: systemImage)
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .accessibilityLabel("\(title): \(value)")
  }

  private var normalOverviewHeader: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center) {
        Image(systemName: "sparkles.rectangle.stack")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .white.opacity(0.7))
          .font(.system(size: 34, weight: .semibold))
          .frame(width: 56, height: 56)
          .background(
            Color.orange.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        VStack(alignment: .leading, spacing: 6) {
          Text("Tune Speak to match your flow")
            .font(.title2.bold())
            .foregroundStyle(.white)
          Text(
            "Choose recording modes, manage keys, and keep permissions in sync—all in one place."
          )
          .font(.callout)
          .foregroundStyle(.white.opacity(0.8))
        }
        Spacer()
      }

      HStack(spacing: 16) {
        overviewChip(
          title: "Mode", value: overviewModeValue, systemImage: "waveform")
        overviewChip(
          title: settings.isActiveAssemblyAILiveModel ? "Pre-processing" : "Post-processing",
          value: overviewPostProcessingValue,
          systemImage: "wand.and.stars")
        overviewChip(
          title: "Output", value: settings.textOutputMethod.displayName,
          systemImage: "text.alignleft")
        overviewChip(
          title: "OpenRouter Key", value: isOpenRouterKeyStored ? "Stored" : "Missing",
          systemImage: isOpenRouterKeyStored ? "checkmark.seal.fill" : "key.fill")
      }
    }
    .padding(24)
    .background(
      LinearGradient(
        colors: [Color.orange, Color.orange.opacity(0.7)], startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .cornerRadius(24)
      .shadow(color: Color.orange.opacity(0.3), radius: 18, x: 0, y: 12)
    )
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
      voiceOutputSettings
    case .pronunciation:
      pronunciationSettings
    case .apiKeys:
      apiKeySettings
    case .shortcuts:
      keyboardSettings
    case .permissions:
      permissionsSettings
    case .about:
      aboutSettings
    }
  }

  var audioInputSelectionBinding: Binding<String> {
    Binding(
      get: {
        audioDevices.selectedDeviceUID ?? AudioInputDeviceManager.systemDefaultToken
      },
      set: { newValue in
        if newValue == AudioInputDeviceManager.systemDefaultToken {
          audioDevices.selectSystemDefault()
        } else {
          audioDevices.selectDevice(uid: newValue)
        }
      }
    )
  }

  init(tab: SettingsTab = .general, sidebarSelection: Binding<SidebarItem?>) {
    self.tab = tab
    _sidebarSelection = sidebarSelection
  }

  private var overviewModeValue: String {
    settings.effectiveTranscriptionModeDisplayName
  }

  var transcriptionLocationBinding: Binding<TranscriptionLocation> {
    Binding(
      get: { settings.transcriptionLocation },
      set: { settings.selectTranscriptionLocation($0) }
    )
  }

  var localTranscriptionSourceBinding: Binding<LocalTranscriptionSource> {
    Binding(
      get: { settings.localTranscriptionSource },
      set: { settings.selectLocalTranscriptionSource($0) }
    )
  }

  var remoteTranscriptionModeBinding: Binding<RemoteTranscriptionMode> {
    Binding(
      get: { settings.remoteTranscriptionMode },
      set: { settings.selectRemoteTranscriptionMode($0) }
    )
  }

  func transcriptionModeSegmentLabel(from displayName: String) -> String {
    displayName
      .replacingOccurrences(of: "Local ", with: "")
      .replacingOccurrences(of: "Remote ", with: "")
  }

  var isStreamingTranscriptionSelected: Bool { settings.isStreamingTranscriptionSelected }

  var isAppleOnDeviceTranscriptionSelected: Bool { settings.isAppleOnDeviceTranscriptionSelected }

  var isLocalTranscriptionSelected: Bool { settings.isLocalTranscriptionSelected }

  var isRemoteStreamingTranscriptionSelected: Bool { settings.isRemoteStreamingTranscriptionSelected }

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

  var localPostProcessingModelBinding: Binding<String> {
    Binding(
      get: {
        if PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel) {
          guard localPostProcessingOptions.contains(where: { $0.id == settings.postProcessingModel }) else {
            return localPostProcessingOptions.first?.id ?? LocalPostProcessingModelManager.builtInRulesModelID
          }
          return settings.postProcessingModel
        }
        return localPostProcessingOptions.first?.id ?? LocalPostProcessingModelManager.builtInRulesModelID
      },
      set: { model in
        guard PostProcessingManager.isLocalPostProcessingModel(model),
          localPostProcessingOptions.contains(where: { $0.id == model })
        else { return }
        settings.postProcessingModel = model
      }
    )
  }

  var localTranscriptionModelBinding: Binding<String> {
    Binding(
      get: {
        guard localTranscriptionOptions.contains(where: { $0.id == settings.localTranscriptionModel }) else {
          return localTranscriptionOptions.first?.id ?? ""
        }
        return settings.localTranscriptionModel
      },
      set: { model in
        guard localTranscriptionOptions.contains(where: { $0.id == model }) else { return }
        settings.localTranscriptionModel = model
      }
    )
  }

  private var postProcessingLocationBinding: Binding<PostProcessingLocation> {
    Binding(
      get: {
        PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel) ? .local : .remote
      },
      set: { location in
        let currentLocation = PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel)
          ? PostProcessingLocation.local
          : .remote
        guard location != currentLocation else { return }
        selectPostProcessingLocation(location)
      }
    )
  }

  var postProcessingLocationSelector: some View {
    HStack(spacing: 8) {
      ForEach(PostProcessingLocation.allCases) { location in
        Button {
          postProcessingLocationBinding.wrappedValue = location
        } label: {
          Text(location.displayName)
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(postProcessingLocationBinding.wrappedValue == location ? .white : .primary)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(postProcessingLocationBinding.wrappedValue == location ? Color.brandAccent : Color.clear)
        )
      }
    }
    .fixedSize()
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private func selectPostProcessingLocation(_ location: PostProcessingLocation) {
    switch location {
    case .local:
      settings.postProcessingModel = localPostProcessingOptions.first?.id ?? "local/post-processing/rules"
    case .remote:
      settings.postProcessingModel = cloudPostProcessingOptions.first {
        $0.id == "openai/gpt-5-mini"
      }?.id ?? cloudPostProcessingOptions.first?.id ?? settings.postProcessingModel
    }
  }

  private func overviewChip(title: String, value: String, systemImage: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white.opacity(0.8))
      Text(value)
        .font(.headline)
        .foregroundStyle(.white)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  func localModelBadge(_ title: String, tint: Color) -> some View {
    Text(title)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Capsule().fill(tint.opacity(0.12)))
  }

  func selectedModelBadge(tint: Color = .green) -> some View {
    Label("Selected", systemImage: "checkmark.circle.fill")
      .font(.caption.weight(.semibold))
      .foregroundStyle(tint)
  }

  func localModelRowContainer<Content: View>(
    isSelected: Bool,
    tint: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(isSelected ? tint.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(isSelected ? tint.opacity(0.8) : Color.clear, lineWidth: isSelected ? 2 : 0)
      )
      .shadow(color: isSelected ? tint.opacity(0.16) : .clear, radius: 10, y: 3)
  }

  func previewRecordingSound(_ sound: RecordingSoundPlayer.RecordingSound) {
    let player = RecordingSoundPlayer()
    player.profile = settings.recordingSoundProfile
    player.play(sound, volume: settings.recordingSoundVolume)
    soundPreviewPlayer = player
  }

  var body: some View {
    let density = settings.visualDensity
    ScrollView {
      VStack(alignment: .leading, spacing: density.isCompact ? density.sectionSpacing : 28) {
        overviewHeader
        tabContent
      }
      .padding(density.pagePadding)
      .frame(maxWidth: 1100, alignment: .center)
    }
    .background(
      LinearGradient(
        colors: [Color.brandAccentWarm.opacity(0.08), .clear], startPoint: .top, endPoint: .center))
    .task {
      transcriptionProviders = await TranscriptionProviderRegistry.shared.allProviders()
      syncAssemblyAIKeytermsFromPronunciation()
      await resolveAPIKeyStorage()
    }
    .onChange(of: settings.liveTranscriptionModel) { _, newValue in
      let newIsAssembly = newValue.localizedCaseInsensitiveContains("assemblyai")
      if newIsAssembly {
        settings.postProcessingEnabled = false
        syncAssemblyAIKeytermsFromPronunciation()
      }
    }
    .onChange(of: settings.assemblyAIKeyterms) { _, _ in
      syncIgnoredPronunciationKeyterms()
    }
    .onChange(of: settings.ttsPronunciationDictionary) { _, _ in
      syncAssemblyAIKeytermsFromPronunciation()
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
        environment.apiKeysScrollTarget = alert.provider.id == "elevenlabs"
          ? "tts-elevenlabs"
          : "transcription-\(alert.provider.id)"
        sidebarSelection = .settings(.apiKeys)
        missingTranscriptionAPIKeyAlert = nil
      }
      if let url = alert.provider.apiKeyURL {
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
      syncAssemblyAIKeytermsFromPronunciation()
    }
  }

  private var voiceOutputSettings: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
      SettingsCard(title: "Default Voice", systemImage: "speaker.wave.3", tint: Color.brandLagoonDeep) {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            Picker("Voice", selection: settingsBinding(\AppSettings.defaultTTSVoice)) {
              ForEach(VoiceCatalog.allVoices) { voice in
                HStack {
                  Text(voice.displayName)
                  Spacer()
                  ModelCredentialStatusView(
                    availability: ModelCredentialResolver.availability(
                      for: voice.id,
                      purpose: .voiceOutput,
                      storedAPIKeyIdentifiers: settings.trackedAPIKeyIdentifiers
                    )
                  )
                }
                .accessibilityElement(children: .combine)
                .tag(voice.id)
              }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            )
            .speakTooltip("Choose your preferred voice for text-to-speech synthesis")

            Text("Your default voice for converting text to speech")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Picker("Language", selection: settingsBinding(\AppSettings.ttsLanguageIdentifier)) {
            ForEach(VoiceOutputLanguageCatalog.options) { option in
              Text(option.displayName).tag(option.id)
            }
          }
          .pickerStyle(.menu)

          if TTSProvider.from(voiceID: settings.defaultTTSVoice) == .soniox {
            Picker("Soniox Region", selection: settingsBinding(\AppSettings.sonioxTTSRegion)) {
              ForEach(SonioxTTSRegion.allCases) { region in
                Text(region.displayName).tag(region)
              }
            }
            .pickerStyle(.segmented)
          }
        }
      }
      .speakTooltip("Select which voice to use by default when generating speech from text.")

      SettingsCard(title: "Audio Quality & Performance", systemImage: "waveform.circle", tint: Color.green) {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            Picker("Quality", selection: settingsBinding(\AppSettings.ttsQuality)) {
              ForEach(TTSQuality.allCases) { quality in
                Text(quality.displayName).tag(quality)
              }
            }
            .pickerStyle(.segmented)

            Text(settings.ttsQuality.description)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .speakTooltip("Fast uses low-latency models, Best Quality uses HD models")

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Speed")
              Spacer()
              Text(String(format: "%.2fx", settings.ttsSpeed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Slider(value: settingsBinding(\AppSettings.ttsSpeed), in: 0.5...2.0, step: 0.1)
              .speakTooltip("Adjust playback speed from 0.5x (slower) to 2.0x (faster)")
          }

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Pitch")
              Spacer()
              Text("\(settings.ttsPitch > 0 ? "+" : "")\(Int(settings.ttsPitch)) semitones")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Slider(value: settingsBinding(\AppSettings.ttsPitch), in: -12...12, step: 1)
              .speakTooltip("Adjust voice pitch from -12 (lower) to +12 (higher) semitones")
          }
        }
      }
      .speakTooltip("Control audio quality, playback speed, and voice pitch for generated speech.")

      SettingsCard(title: "Output & Export", systemImage: "arrow.down.circle", tint: Color.brandAccentWarm) {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            Picker("File Format", selection: settingsBinding(\AppSettings.ttsOutputFormat)) {
              ForEach(AudioFormat.allCases) { format in
                Text(format.displayName).tag(format)
              }
            }
            .pickerStyle(.segmented)
            .speakTooltip("Choose the audio file format for exported speech")
          }

          settingsToggle(
            "Auto-play after synthesis",
            isOn: settingsBinding(\AppSettings.ttsAutoPlay),
            tint: .brandAccentWarm
          )
          .speakTooltip("Automatically play audio after synthesis completes")

          settingsToggle(
            "Save to recordings directory",
            isOn: settingsBinding(\AppSettings.ttsSaveToDirectory),
            tint: .brandAccentWarm
          )
          .speakTooltip("Automatically save generated speech files to your recordings folder")

          settingsToggle(
            "Enable SSML support",
            isOn: settingsBinding(\AppSettings.ttsUseSSML),
            tint: .brandAccentWarm
          )
          .speakTooltip("Enable Speech Synthesis Markup Language for advanced voice control")
        }
      }
      .speakTooltip("Configure how generated speech is saved and played back.")

      SettingsCard(title: "Favorite Voices", systemImage: "star.fill", tint: Color.yellow) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Quick access to your preferred voices")
            .font(.caption)
            .foregroundStyle(.secondary)

          if settings.ttsFavoriteVoices.isEmpty {
            Text("No favorites yet. Add voices from the Voice Output view.")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .padding(.vertical, 8)
          } else {
            ForEach(settings.ttsFavoriteVoices, id: \.self) { voiceID in
              if let voice = VoiceCatalog.voice(forID: voiceID) {
                HStack {
                  Text(voice.displayName)
                    .font(.subheadline)
                  Spacer()
                  Button {
                    settings.ttsFavoriteVoices.removeAll { $0 == voiceID }
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                      .foregroundStyle(.secondary)
                  }
                  .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
              }
            }
          }
        }
      }
      .speakTooltip("Manage your favorite voices for quick access.")

      SettingsCard(title: "Pronunciation Dictionary", systemImage: "text.book.closed", tint: Color.brandAccent) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Custom pronunciations for words the TTS mispronounces")
            .font(.caption)
            .foregroundStyle(.secondary)

          if settings.ttsPronunciationDictionary.isEmpty {
            Text("No custom pronunciations. Add words that are commonly mispronounced.")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .padding(.vertical, 8)
          } else {
            ForEach(Array(settings.ttsPronunciationDictionary.keys.sorted()), id: \.self) { word in
              if let pronunciation = settings.ttsPronunciationDictionary[word] {
                HStack {
                  Text(word)
                    .font(.subheadline.bold())
                  Text("→")
                    .foregroundStyle(.secondary)
                  Text(pronunciation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                  Spacer()
                  Button {
                    settings.ttsPronunciationDictionary.removeValue(forKey: word)
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                      .foregroundStyle(.secondary)
                  }
                  .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
              }
            }
          }

          Divider()

          PronunciationEntryView(dictionary: Binding(
            get: { settings.ttsPronunciationDictionary },
            set: { settings.ttsPronunciationDictionary = $0 }
          ))
        }
      }
      .speakTooltip("Add custom pronunciations for words that TTS engines commonly mispronounce.")
    }
  }

  private var pronunciationSettings: some View {
    PronunciationDictionaryView()
      .environmentObject(environment.pronunciationManager)
  }

  func saveAPIKey() {
    apiKeyValidationState = .validating
    let value = newAPIKeyValue.trimmingCharacters(in: .whitespacesAndNewlines)

    Task {
      let validation = await environment.openRouter.validateAPIKey(value)

      switch validation.outcome {
      case .success:
        do {
          try await environment.secureStorage.storeSecret(
            value,
            identifier: openRouterKeyIdentifier,
            label: "OpenRouter API Key"
          )

          let result = validation.updatingOutcome(
            .success(message: "Key saved and validated")
          )

          await MainActor.run {
            apiKeyValidationState = .finished(result)
            newAPIKeyValue = ""
          }
        } catch {
          let failure = APIKeyValidationResult.failure(
            message: "Failed to store key: \(error.localizedDescription)",
            debug: validation.debug
          )
          await MainActor.run {
            apiKeyValidationState = .finished(failure)
          }
        }
      case .failure:
        await MainActor.run {
          apiKeyValidationState = .finished(validation)
        }
      }
    }
  }

  private func parseAssemblyAIKeyterms(_ raw: String) -> [String] {
    raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter(isValidAssemblyAIKeyterm)
  }

  private func canonicalKeyterm(_ term: String) -> String {
    term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func isValidAssemblyAIKeyterm(_ term: String) -> Bool {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.contains(",") && trimmed.count <= 50
  }

  private func pronunciationSeedKeyterms() -> [String] {
    let modernDictionaryTerms = environment.pronunciationManager.entries
      .filter { !$0.isRegex }
      .map(\.word)
    let legacyDictionaryTerms = settings.ttsPronunciationDictionary.keys.sorted()

    var terms: [String] = []
    var seen: Set<String> = []
    for raw in modernDictionaryTerms + legacyDictionaryTerms {
      let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      let canonical = canonicalKeyterm(term)
      guard
        isValidAssemblyAIKeyterm(term),
        seen.insert(canonical).inserted
      else { continue }
      terms.append(term)
    }
    return terms
  }

  private func syncAssemblyAIKeytermsFromPronunciation() {
    guard settings.isActiveAssemblyAILiveModel else { return }

    let seedTerms = pronunciationSeedKeyterms()
    let ignoredPronunciationTerms = Set(
      settings.assemblyAIIgnoredPronunciationTerms.map(canonicalKeyterm))
    let currentTerms = parseAssemblyAIKeyterms(settings.assemblyAIKeyterms)

    var mergedTerms: [String] = []
    var seen: Set<String> = []
    for term in currentTerms {
      let canonical = canonicalKeyterm(term)
      guard seen.insert(canonical).inserted else { continue }
      mergedTerms.append(term)
    }
    for term in seedTerms where !ignoredPronunciationTerms.contains(canonicalKeyterm(term)) {
      let canonical = canonicalKeyterm(term)
      guard seen.insert(canonical).inserted else { continue }
      mergedTerms.append(term)
    }

    let mergedKeyterms = Array(mergedTerms.prefix(100)).joined(separator: ", ")
    if mergedKeyterms != settings.assemblyAIKeyterms {
      settings.assemblyAIKeyterms = mergedKeyterms
    }

    syncIgnoredPronunciationKeyterms(seedTerms: seedTerms)
  }

  private func syncIgnoredPronunciationKeyterms(seedTerms: [String]? = nil) {
    guard settings.isActiveAssemblyAILiveModel else { return }

    let pronunciationTerms = seedTerms ?? pronunciationSeedKeyterms()
    let selectedTermSet = Set(parseAssemblyAIKeyterms(settings.assemblyAIKeyterms).map(canonicalKeyterm))
    var ignoredSet = Set(settings.assemblyAIIgnoredPronunciationTerms.map(canonicalKeyterm))

    for term in pronunciationTerms {
      let canonical = canonicalKeyterm(term)
      if selectedTermSet.contains(canonical) {
        ignoredSet.remove(canonical)
      } else {
        ignoredSet.insert(canonical)
      }
    }

    let updatedIgnored = ignoredSet.sorted()
    if updatedIgnored != settings.assemblyAIIgnoredPronunciationTerms {
      settings.assemblyAIIgnoredPronunciationTerms = updatedIgnored
    }
  }

  func settingsBinding<Value: Hashable>(
    _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: { settings[keyPath: keyPath] = $0 }
    )
  }

  func settingsToggle(_ label: String, isOn: Binding<Bool>, tint: Color) -> some View {
    Toggle(label, isOn: isOn)
      .tint(tint)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
  }

  func speedModeIcon(for mode: AppSettings.SpeedMode) -> String {
    switch mode {
    case .instant:
      return "bolt.fill"
    case .livePolish:
      return "sparkles"
    }
  }

  @MainActor
  // swiftlint:disable:next function_body_length
  func generateSystemPromptPreview() {
    if PostProcessingManager.isBuiltInLocalPostProcessingModel(settings.postProcessingModel) {
      self.systemPromptPreview = """
      The built-in rules cleaner does not send a prompt.

      It runs deterministic local cleanup rules on the raw transcript. Lexicon directives and context tags apply to \
      remote models and downloaded local LLMs only.
      """
      return
    }

    let rawLanguage = self.settings.postProcessingOutputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    let language: String
    if rawLanguage.uppercased() == "ENGB" || rawLanguage.lowercased() == "en_gb" {
      language = "British English"
    } else {
      language = rawLanguage
    }

    let lexiconCount = self.environment.personalLexicon.rules.count
    let effectiveSystemPrompt = TranscriptCleanupPolicy.systemPrompt(
      outputLanguage: language,
      lexiconDirectives: self.settings.postProcessingIncludeLexiconDirectives
        ? ["[Example: \(lexiconCount) active correction rules will be inserted here]"]
        : [],
      lexiconContextTags: self.settings.postProcessingIncludeContextTags
        ? ["Tags will be inserted based on active app context"]
        : []
    )

    if PostProcessingManager.isDownloadedLocalPostProcessingModel(settings.postProcessingModel) {
      let localUserPrompt = LocalPostProcessingModelManager.localUserPrompt(
        systemPrompt: effectiveSystemPrompt,
        rawText: "{{RAW_TRANSCRIPT}}"
      )
      self.systemPromptPreview = """
      System prompt sent to the local model:

      \(LocalPostProcessingModelManager.localSystemPrompt(effectiveSystemPrompt))

      User prompt sent to the local model:

      \(localUserPrompt)
      """
      return
    }

    self.systemPromptPreview = """
    System prompt:

    \(effectiveSystemPrompt)

    User message preview:

    \(TranscriptCleanupPolicy.userMessage(transcript: "{{RAW_TRANSCRIPT}}"))
    """
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
// swiftlint:enable file_length type_body_length
