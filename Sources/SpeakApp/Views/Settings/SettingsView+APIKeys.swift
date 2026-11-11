import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

extension SettingsView {
  var apiKeySettings: some View {
    ScrollViewReader { proxy in
      VStack(spacing: settings.visualDensity.sectionSpacing) {
        SpeakDensitySettingsSection(
          density: settings.visualDensity,
          compactMinimumWidth: 320,
          maximumColumns: 2
        ) {
          if PaidAccessFeature.isEnabled {
            paidAccessCard
          }

          apiKeyListControls
          SettingsCard(title: "Alibaba workspace for new keys", systemImage: "waveform", tint: .brandAccent) {
            AlibabaSpeechConfigurationFields()
          }
          SettingsCard(title: "Azure Speech resource", systemImage: "cloud", tint: .brandAccent) {
            AzureSpeechEndpointField()
          }

          if DistributionChannel.current.supportsEncryptedCloudKitKeySync {
            CloudKitKeySyncSettingsCard(secureStorage: environment.secureStorage)
          } else {
            LocalKeychainStorageCard()
          }
        }

        if visibleMacAPIKeyItems.isEmpty {
          let empty = APIKeyListQuery.emptyState(status: apiKeyStatusFilter, searchText: apiKeySearchText)
          ContentUnavailableView(empty.title, systemImage: empty.systemImage, description: Text(empty.message))
            .padding(.vertical, 24)
            .accessibilityIdentifier("apiKeysEmptyState")
        } else {
          SpeakDensitySettingsSection(
            density: settings.visualDensity,
            compactMinimumWidth: 320
          ) {
            ForEach(visibleMacAPIKeyItems) { item in
              macAPIKeyView(for: item)
                .settingsSearchHighlight(entryID: MacSettingsSearch.apiKeyEntryPrefix + item.id)
                .id(item.id)
            }
          }
        }
      }
      // Covers both the initial appearance and later target changes; the work is
      // cancelled with the view instead of firing from a detached timer.
      .task(id: environment.apiKeysScrollTarget) {
        guard let target = environment.apiKeysScrollTarget else { return }
        revealAPIKeyTarget()
        // Give the reveal above a beat to expand its section before scrolling.
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        withAnimation { proxy.scrollTo(target, anchor: .top) }
        environment.apiKeysScrollTarget = nil
      }
      // Balances are read from the same Keychain the cards write to. The work
      // is cancelled with the view, and a failure only changes what the balance
      // line says — the rest of the screen is unaffected.
      .task {
        let secureStorage = environment.secureStorage
        apiKeyForm.balances.configure { identifier in
          try? await secureStorage.secret(identifier: identifier)
        }
        apiKeyForm.balances.refreshAll(
          storedCredentialIdentifiers: Set(settings.trackedAPIKeyIdentifiers)
        )
      }
      .onDisappear { apiKeyForm.balances.cancelAll() }
    }
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

  private var apiKeySearchField: some View {
    TextField("Search provider or category", text: $apiKeySearchText)
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("Search API keys")
  }

  private var apiKeyListControls: some View {
    SettingsCard(title: "Find API Keys", systemImage: "magnifyingglass", tint: .brandAccent) {
      if settings.visualDensity.isCompact {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: settings.visualDensity.inlineSpacing) {
            apiKeySearchField
              .frame(minWidth: 180)

            apiKeyFilterControls
              .fixedSize(horizontal: true, vertical: false)
          }

          VStack(alignment: .leading, spacing: settings.visualDensity.inlineSpacing) {
            apiKeySearchField
            apiKeyFilterControls
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          apiKeySearchField

          apiKeyFilterControls
        }
      }
    }
  }

  private var apiKeyFilterControls: some View {
    HStack(spacing: settings.visualDensity.inlineSpacing) {
      Picker("Status", selection: $apiKeyStatusFilter) {
        ForEach(APIKeyStatusFilter.allCases) { filter in
          Text(filter.displayName).tag(filter)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("apiKeysStatusFilter")

      Picker("Sort", selection: $apiKeySortOrder) {
        ForEach(APIKeySortOrder.allCases) { order in
          Text(order.displayName).tag(order)
        }
      }
      .pickerStyle(.menu)

      Spacer(minLength: 0)
      Text(
        settings.visualDensity.isCompact
          ? "\(visibleMacAPIKeyItems.count)/\(allMacAPIKeyItems.count)"
          : "\(visibleMacAPIKeyItems.count) of \(allMacAPIKeyItems.count)"
      )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityLabel(
          "\(visibleMacAPIKeyItems.count) of \(allMacAPIKeyItems.count) API keys shown"
        )
    }
  }

  @ViewBuilder
  private func macAPIKeyView(for item: MacAPIKeyItem) -> some View {
    switch item.source {
    case .openRouter:
      apiKeyCard(APIKeyCardConfiguration(
        title: "OpenRouter",
        systemImage: "network",
        tint: .green,
        statusIcon: isOpenRouterKeyStored ? "checkmark.seal.fill" : "key.fill",
        statusTint: .green,
        isStored: isOpenRouterKeyStored,
        descriptionText: "Stored securely in your macOS Keychain. Shared by OpenRouter transcription, "
          + "voice output and post-processing.",
        keyFieldLabel: "OpenRouter API Key",
        keyBinding: $apiKeyForm.openRouterDraft,
        onSave: { apiKeyForm.saveOpenRouterKey(in: environment) },
        onValidate: isOpenRouterKeyStored ? { apiKeyForm.checkOpenRouterKey(in: environment) } : nil,
        onRemove: isOpenRouterKeyStored ? { apiKeyForm.removeOpenRouterKey(in: environment) } : nil,
        isSaveDisabled: apiKeyForm.isValidatingOpenRouterKey
          || apiKeyForm.openRouterDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        isValidateDisabled: apiKeyForm.isValidatingOpenRouterKey,
        isRemoveDisabled: apiKeyForm.isValidatingOpenRouterKey,
        validationState: apiKeyForm.openRouterState,
        credentialIdentifier: APIKeyFormModel.openRouterKeyIdentifier,
        tooltip: "Securely store and validate the OpenRouter key Speak uses for advanced models.",
        saveButtonTitle: isOpenRouterKeyStored ? "Replace Key" : "Save Key",
        saveTooltip: "Store this OpenRouter key safely in your macOS Keychain for Speak to use when needed.",
        validateButtonTitle: "Check Validity",
        validateTooltip: "Make sure your saved key still works before you rely on it in a session.",
        removeButtonTitle: "Remove Key",
        removeTooltip: "Forget this key from Speak and your Keychain if you no longer need it.",
        link: OpenRouterService.apiKeysURL,
        linkLabel: "Get API Key",
        guideUses: [.transcription, .postProcessing, .voiceOutput]
      ))
    case .transcription(let provider):
      providerAPIKeyCard(for: provider)
    case .textToSpeech(let provider):
      ttsProviderAPIKeyCard(for: provider)
    }
  }

  private func revealAPIKeyTarget() {
    apiKeySearchText = ""
    apiKeyStatusFilter = .all
  }

  private func providerAPIKeyCard(for provider: TranscriptionProviderMetadata) -> some View {
    let isStored = isAPIKeyStored(provider.apiKeyIdentifier)
    let tintColor = colorFromString(provider.tintColor)
    let validationState = apiKeyForm.providerStates[provider.id] ?? .idle
    let inFlight = validationState.isInFlight
    let saveDisabled = inFlight
      || (apiKeyForm.providerDrafts[provider.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let validateDisabled = inFlight || !isStored
    let removeDisabled = inFlight

    return apiKeyCard(APIKeyCardConfiguration(
      title: "\(provider.displayName) (Transcription)",
      systemImage: provider.systemImage,
      tint: tintColor,
      statusIcon: isStored ? "checkmark.seal.fill" : "key.fill",
      statusTint: tintColor,
      isStored: isStored,
      descriptionText: "Stored securely in your macOS Keychain. Used only for \(provider.displayName) transcription.",
      keyFieldLabel: provider.apiKeyLabel,
      keyBinding: apiKeyForm.providerDraft(for: provider.id),
      onSave: { apiKeyForm.saveProviderKey(provider, in: environment) },
      onValidate: isStored ? { apiKeyForm.checkProviderKey(provider, in: environment) } : nil,
      onRemove: isStored ? { apiKeyForm.removeProviderKey(provider, in: environment) } : nil,
      isSaveDisabled: saveDisabled,
      isValidateDisabled: validateDisabled,
      isRemoveDisabled: removeDisabled,
      validationState: validationState,
      credentialIdentifier: provider.apiKeyIdentifier,
      tooltip: "Manage your \(provider.displayName) API key securely without leaving Speak.",
      saveButtonTitle: isStored ? "Replace Key" : "Save Key",
      saveTooltip: "Securely store your \(provider.displayName) key so Speak can contact the service when needed.",
      validateButtonTitle: "Check Validity",
      validateTooltip: "Confirm that your \(provider.displayName) key is still valid before a big session.",
      removeButtonTitle: "Remove Key",
      removeTooltip: "Forget this service key from Speak and your Keychain when you no longer use it.",
      link: APIKeyCatalog.keyPageURL(for: provider.apiKeyIdentifier)
        ?? (provider.website.isEmpty ? nil : URL(string: provider.website)),
      linkLabel: "Get API Key",
      guideUses: .transcription
    ))
  }

  // swiftlint:disable:next function_body_length
  private func ttsProviderAPIKeyCard(for provider: TTSProvider) -> some View {
    let isStored = isAPIKeyStored(provider.apiKeyIdentifier)
    let validationState = apiKeyForm.ttsStates[provider.rawValue] ?? .idle
    let inFlight = validationState.isInFlight
    let saveDisabled = inFlight
      || (apiKeyForm.ttsDrafts[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let validateDisabled = inFlight || !isStored
    let removeDisabled = inFlight

    let tintColor = provider.apiKeyCardTint
    let systemImage = provider.apiKeyCardSystemImage
    let website = provider.apiKeyWebsite
    let descriptionText = provider.apiKeyCardDescription

    // ElevenLabs is the shared credential card for both TTS and Scribe transcription.
    // Keep it out of the transcription-provider ForEach; one card covers both capabilities.
    if provider == .elevenlabs {
      return apiKeyCard(APIKeyCardConfiguration(
        title: "ElevenLabs API Key",
        systemImage: systemImage,
        tint: tintColor,
        statusIcon: isStored ? "checkmark.seal.fill" : "key.fill",
        statusTint: tintColor,
        isStored: isStored,
        descriptionText: "Stored securely in your macOS Keychain. Used for ElevenLabs Text-to-Speech "
          + "voice synthesis and Scribe transcription. The key must have both TTS and speech-to-text permissions.",
        keyFieldLabel: "ElevenLabs API Key",
        keyBinding: apiKeyForm.ttsDraft(for: provider.rawValue),
        onSave: { apiKeyForm.saveTTSKey(provider, in: environment) },
        onValidate: isStored ? { apiKeyForm.checkTTSKey(provider, in: environment) } : nil,
        onRemove: isStored ? { apiKeyForm.removeTTSKey(provider, in: environment) } : nil,
        isSaveDisabled: saveDisabled,
        isValidateDisabled: validateDisabled,
        isRemoveDisabled: removeDisabled,
        validationState: validationState,
        credentialIdentifier: provider.apiKeyIdentifier,
        tooltip: "Manage your ElevenLabs API key. One key covers both voice synthesis (TTS) "
          + "and Scribe transcription (STT).",
        saveButtonTitle: isStored ? "Replace Key" : "Save Key",
        saveTooltip: "Securely store your ElevenLabs key. It will be used for both TTS "
          + "and Scribe transcription.",
        validateButtonTitle: "Check Validity",
        validateTooltip: "Confirm that your ElevenLabs key has access to both TTS "
          + "and Scribe transcription.",
        removeButtonTitle: "Remove Key",
        removeTooltip: "Forget this key from Speak and your Keychain. Disables both ElevenLabs "
          + "TTS and Scribe transcription.",
        link: APIKeyCatalog.keyPageURL(for: provider.apiKeyIdentifier) ?? URL(string: website),
        linkLabel: "Get API Key",
        guideUses: [.transcription, .voiceOutput]
      ))
    }

    return apiKeyCard(APIKeyCardConfiguration(
      title: provider.sharesTranscriptionCredential
        ? "\(provider.displayName) API Key"
        : "\(provider.displayName) (TTS)",
      systemImage: systemImage,
      tint: tintColor,
      statusIcon: isStored ? "checkmark.seal.fill" : "key.fill",
      statusTint: tintColor,
      isStored: isStored,
      descriptionText: descriptionText,
      keyFieldLabel: provider.sharesTranscriptionCredential
        ? "\(provider.displayName) API Key"
        : "\(provider.displayName) TTS API Key",
      keyBinding: apiKeyForm.ttsDraft(for: provider.rawValue),
      onSave: { apiKeyForm.saveTTSKey(provider, in: environment) },
      onValidate: isStored ? { apiKeyForm.checkTTSKey(provider, in: environment) } : nil,
      onRemove: isStored ? { apiKeyForm.removeTTSKey(provider, in: environment) } : nil,
      isSaveDisabled: saveDisabled,
      isValidateDisabled: validateDisabled,
      isRemoveDisabled: removeDisabled,
      validationState: validationState,
      credentialIdentifier: provider.apiKeyIdentifier,
      // A provider that does not share its transcription credential already
      // has a transcription card on the same Keychain item, and that card
      // owns the account balance.
      presentsAccountBalance: provider.sharesTranscriptionCredential,
      tooltip: provider == .azure
        ? "Manage your Azure Speech credential. Local proxy credentials support transcription only."
        : provider.sharesTranscriptionCredential
          ? "Manage your \(provider.displayName) credential for transcription and voice output."
          : "Manage your \(provider.displayName) API key for text-to-speech synthesis.",
      saveButtonTitle: isStored ? "Replace Key" : "Save Key",
      saveTooltip: provider.sharesTranscriptionCredential
        ? "Securely store the shared \(provider.displayName) credential."
        : "Securely store your \(provider.displayName) key for voice synthesis.",
      validateButtonTitle: "Check Validity",
      validateTooltip: "Confirm that your \(provider.displayName) key is still valid.",
      removeButtonTitle: "Remove Key",
      removeTooltip: "Forget this key from Speak and your Keychain.",
      link: APIKeyCatalog.keyPageURL(for: provider.apiKeyIdentifier)
        ?? (website.isEmpty ? nil : URL(string: website)),
      linkLabel: "Get API Key",
      guideUses: provider.sharesTranscriptionCredential ? [.transcription, .voiceOutput] : .voiceOutput
    ))
  }

  private func apiKeyCard(_ configuration: APIKeyCardConfiguration) -> some View {
    APIKeyCard(configuration: configuration, balances: apiKeyForm.balances)
  }

  // This switch maps the existing provider display palette.
  // swiftlint:disable:next cyclomatic_complexity
  private func colorFromString(_ name: String) -> Color {
    switch name.lowercased() {
    case "green": return .green
    case "blue": return .brandLagoon
    case "purple": return .brandAccent
    case "orange": return .brandAccentWarm
    case "red": return .red
    case "pink": return .brandAccentWarm
    case "yellow": return .yellow
    case "cyan": return .brandLagoon
    case "indigo": return .brandAccentDeep
    case "mint": return .mint
    case "teal": return .teal
    default: return .accentColor
    }
  }

}
