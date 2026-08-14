// swiftlint:disable file_length
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
          paidAccessCard

          apiKeyListControls

          if DistributionChannel.current.supportsEncryptedCloudKitKeySync {
            CloudKitKeySyncSettingsCard(secureStorage: environment.secureStorage)
          } else {
            LocalKeychainStorageCard()
          }
        }

        if visibleMacAPIKeyItems.isEmpty {
          ContentUnavailableView(
            "No API Keys",
            systemImage: "key.slash",
            description: Text("Try a different search or status filter.")
          )
          .padding(.vertical, 24)
        } else {
          SpeakDensitySettingsSection(
            density: settings.visualDensity,
            compactMinimumWidth: 320
          ) {
            ForEach(visibleMacAPIKeyItems) { item in
              macAPIKeyView(for: item)
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
    }
  }

  private var apiKeyListControls: some View {
    SettingsCard(title: "Find API Keys", systemImage: "magnifyingglass", tint: .brandAccent) {
      if settings.visualDensity.isCompact {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: settings.visualDensity.inlineSpacing) {
            TextField("Search provider or category", text: $apiKeySearchText)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 180)
              .accessibilityLabel("Search API keys")

            apiKeyFilterControls
              .fixedSize(horizontal: true, vertical: false)
          }

          VStack(alignment: .leading, spacing: settings.visualDensity.inlineSpacing) {
            TextField("Search provider or category", text: $apiKeySearchText)
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel("Search API keys")
            apiKeyFilterControls
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          TextField("Search provider or category", text: $apiKeySearchText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Search API keys")

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
      apiKeyCard(
        title: "OpenRouter",
        systemImage: "network",
        tint: .green,
        statusIcon: isOpenRouterKeyStored ? "checkmark.seal.fill" : "key.fill",
        statusTint: .green,
        isStored: isOpenRouterKeyStored,
        descriptionText: "Stored securely in your macOS Keychain. We only use it when calling OpenRouter.",
        keyFieldLabel: "OpenRouter API Key",
        keyBinding: $newAPIKeyValue,
        onSave: saveAPIKey,
        onValidate: isOpenRouterKeyStored ? checkOpenRouterKeyValidity : nil,
        onRemove: isOpenRouterKeyStored ? removeOpenRouterKey : nil,
        isSaveDisabled: isValidatingKey
          || newAPIKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        isValidateDisabled: isValidatingKey,
        isRemoveDisabled: isValidatingKey,
        validationState: apiKeyValidationState,
        tooltip: "Securely store and validate the OpenRouter key Speak uses for advanced models.",
        saveButtonTitle: isOpenRouterKeyStored ? "Replace Key" : "Save Key",
        saveTooltip: "Store this OpenRouter key safely in your macOS Keychain for Speak to use when needed.",
        validateButtonTitle: "Check Validity",
        validateTooltip: "Make sure your saved key still works before you rely on it in a session.",
        removeButtonTitle: "Remove Key",
        removeTooltip: "Forget this key from Speak and your Keychain if you no longer need it.",
        link: nil,
        linkLabel: nil
      )
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
    let validationState = providerValidationStates[provider.id] ?? .idle
    let inFlight = isValidationInFlight(validationState)
    let saveDisabled = inFlight
      || (providerAPIKeys[provider.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let validateDisabled = inFlight || !isStored
    let removeDisabled = inFlight

    return apiKeyCard(
      title: "\(provider.displayName) (Transcription)",
      systemImage: provider.systemImage,
      tint: tintColor,
      statusIcon: isStored ? "checkmark.seal.fill" : "key.fill",
      statusTint: tintColor,
      isStored: isStored,
      descriptionText: "Stored securely in your macOS Keychain. Used only for \(provider.displayName) transcription.",
      keyFieldLabel: provider.apiKeyLabel,
      keyBinding: binding(for: provider.id),
      onSave: { saveProviderAPIKey(provider) },
      onValidate: isStored ? { checkProviderKeyValidity(provider) } : nil,
      onRemove: isStored ? { removeProviderAPIKey(provider) } : nil,
      isSaveDisabled: saveDisabled,
      isValidateDisabled: validateDisabled,
      isRemoveDisabled: removeDisabled,
      validationState: validationState,
      tooltip: "Manage your \(provider.displayName) API key securely without leaving Speak.",
      saveButtonTitle: isStored ? "Replace Key" : "Save Key",
      saveTooltip: "Securely store your \(provider.displayName) key so Speak can contact the service when needed.",
      validateButtonTitle: "Check Validity",
      validateTooltip: "Confirm that your \(provider.displayName) key is still valid before a big session.",
      removeButtonTitle: "Remove Key",
      removeTooltip: "Forget this service key from Speak and your Keychain when you no longer use it.",
      link: provider.website.isEmpty ? nil : URL(string: provider.website),
      linkLabel: provider.website.isEmpty ? nil : "Get API Key"
    )
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func ttsProviderAPIKeyCard(for provider: TTSProvider) -> some View {
    let isStored = isAPIKeyStored(provider.apiKeyIdentifier)
    let validationState = ttsProviderValidationStates[provider.rawValue] ?? .idle
    let inFlight = isValidationInFlight(validationState)
    let saveDisabled = inFlight
      || (ttsProviderAPIKeys[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let validateDisabled = inFlight || !isStored
    let removeDisabled = inFlight

    let tintColor: Color = {
      switch provider {
      case .elevenlabs: return .brandAccent
      case .openai: return .green
      case .azure: return .brandLagoonDeep
      case .deepgram: return .brandAccentWarm
      case .soniox: return .brandLagoon
      case .system: return .gray
      }
    }()
    let systemImage: String = {
      switch provider {
      case .elevenlabs: return "waveform.circle"
      case .openai: return "brain"
      case .azure: return "cloud"
      case .deepgram: return "bolt.circle"
      case .soniox: return "globe"
      case .system: return "speaker.wave.2"
      }
    }()
    let website: String = {
      switch provider {
      case .elevenlabs: return "https://elevenlabs.io"
      case .openai: return "https://platform.openai.com"
      case .azure: return "https://azure.microsoft.com/en-us/services/cognitive-services/text-to-speech/"
      case .deepgram: return "https://deepgram.com"
      case .soniox: return "https://soniox.com"
      case .system: return ""
      }
    }()
    // Soniox uses one account key for transcription and speech generation, so
    // this is the only card for it — the transcription list skips it.
    let descriptionText: String = {
      switch provider {
      case .azure:
        return "For Azure Text-to-Speech, use format: 'your-api-key:your-region' (e.g., 'abc123:eastus')"
      case .soniox:
        return "Stored securely in your macOS Keychain. Used for Soniox transcription and for "
          + "Soniox TTS v2 voice output in 60+ languages."
      default:
        return "Stored securely in your macOS Keychain. Used only for "
          + "\(provider.displayName) text-to-speech voice synthesis."
      }
    }()

    // ElevenLabs is the shared credential card for both TTS and Scribe transcription.
    // Keep it out of the transcription-provider ForEach; one card covers both capabilities.
    if provider == .elevenlabs {
      return apiKeyCard(
        title: "ElevenLabs API Key",
        systemImage: systemImage,
        tint: tintColor,
        statusIcon: isStored ? "checkmark.seal.fill" : "key.fill",
        statusTint: tintColor,
        isStored: isStored,
        descriptionText: "Stored securely in your macOS Keychain. Used for ElevenLabs Text-to-Speech "
          + "voice synthesis and Scribe transcription. The key must have both TTS and speech-to-text permissions.",
        keyFieldLabel: "ElevenLabs API Key",
        keyBinding: ttsBinding(for: provider.rawValue),
        onSave: { saveTTSProviderAPIKey(provider) },
        onValidate: isStored ? { checkTTSProviderKeyValidity(provider) } : nil,
        onRemove: isStored ? { removeElevenLabsAPIKey() } : nil,
        isSaveDisabled: saveDisabled,
        isValidateDisabled: validateDisabled,
        isRemoveDisabled: removeDisabled,
        validationState: validationState,
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
        link: URL(string: website),
        linkLabel: "Get API Key"
      )
    }

    return apiKeyCard(
      title: provider == .soniox ? "Soniox API Key" : "\(provider.displayName) (TTS)",
      systemImage: systemImage,
      tint: tintColor,
      statusIcon: isStored ? "checkmark.seal.fill" : "key.fill",
      statusTint: tintColor,
      isStored: isStored,
      descriptionText: descriptionText,
      keyFieldLabel: provider == .soniox
        ? "Soniox API Key"
        : "\(provider.displayName) TTS API Key",
      keyBinding: ttsBinding(for: provider.rawValue),
      onSave: { saveTTSProviderAPIKey(provider) },
      onValidate: isStored ? { checkTTSProviderKeyValidity(provider) } : nil,
      onRemove: isStored ? { removeTTSProviderAPIKey(provider) } : nil,
      isSaveDisabled: saveDisabled,
      isValidateDisabled: validateDisabled,
      isRemoveDisabled: removeDisabled,
      validationState: validationState,
      tooltip: "Manage your \(provider.displayName) API key for text-to-speech synthesis.",
      saveButtonTitle: isStored ? "Replace Key" : "Save Key",
      saveTooltip: "Securely store your \(provider.displayName) key for voice synthesis.",
      validateButtonTitle: "Check Validity",
      validateTooltip: "Confirm that your \(provider.displayName) key is still valid.",
      removeButtonTitle: "Remove Key",
      removeTooltip: "Forget this key from Speak and your Keychain.",
      link: website.isEmpty ? nil : URL(string: website),
      linkLabel: website.isEmpty ? nil : "Get API Key"
    )
  }

  private func apiKeyCard(
    title: String,
    systemImage: String,
    tint: Color,
    statusIcon: String,
    statusTint: Color,
    isStored: Bool,
    descriptionText: String,
    keyFieldLabel: String,
    keyBinding: Binding<String>,
    onSave: @escaping () -> Void,
    onValidate: (() -> Void)?,
    onRemove: (() -> Void)?,
    isSaveDisabled: Bool,
    isValidateDisabled: Bool,
    isRemoveDisabled: Bool,
    validationState: ValidationViewState,
    tooltip: String,
    saveButtonTitle: String,
    saveTooltip: String,
    validateButtonTitle: String,
    validateTooltip: String,
    removeButtonTitle: String,
    removeTooltip: String,
    link: URL?,
    linkLabel: String?,
    statusLabel: String = "Status"
  ) -> some View {
    let configuration = APIKeyCardConfiguration(
      title: title,
      tint: tint,
      statusIcon: statusIcon,
      statusTint: statusTint,
      isStored: isStored,
      descriptionText: descriptionText,
      keyFieldLabel: keyFieldLabel,
      keyBinding: keyBinding,
      onSave: onSave,
      onValidate: onValidate,
      onRemove: onRemove,
      isSaveDisabled: isSaveDisabled,
      isValidateDisabled: isValidateDisabled,
      isRemoveDisabled: isRemoveDisabled,
      validationState: validationState,
      saveButtonTitle: saveButtonTitle,
      saveTooltip: saveTooltip,
      validateButtonTitle: validateButtonTitle,
      validateTooltip: validateTooltip,
      removeButtonTitle: removeButtonTitle,
      removeTooltip: removeTooltip,
      link: link,
      linkLabel: linkLabel,
      statusLabel: statusLabel
    )

    return SettingsCard(title: title, systemImage: systemImage, tint: tint) {
      if settings.visualDensity.isCompact {
        compactAPIKeyCardBody(configuration)
      } else {
        regularAPIKeyCardBody(configuration)
      }
    }
    .speakTooltip(tooltip)
  }

  private func compactAPIKeyCardBody(_ configuration: APIKeyCardConfiguration) -> some View {
    VStack(alignment: .leading, spacing: settings.visualDensity.cardContentSpacing) {
      compactAPIKeyStatus(configuration)

      HStack(spacing: settings.visualDensity.inlineSpacing) {
        SecureField(configuration.keyFieldLabel, text: configuration.keyBinding)
          .textContentType(.password)
          .privacySensitive()
          .textFieldStyle(.roundedBorder)
          .speakTooltip("Paste the key exactly as issued; Speak stores it securely in your Keychain.")

        compactAPIKeySaveButton(configuration)
        compactAPIKeyValidateButton(configuration)
        compactAPIKeyRemoveButton(configuration)
      }

      Text(configuration.descriptionText)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .speakTooltip(configuration.descriptionText)

      validationStatusView(for: configuration.validationState)
      validationDebugDetails(for: configuration.validationState)
    }
  }

  private func compactAPIKeyStatus(_ configuration: APIKeyCardConfiguration) -> some View {
    HStack(spacing: settings.visualDensity.inlineSpacing) {
      Label(
        configuration.isStored ? "Saved" : "Not set",
        systemImage: configuration.statusIcon
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(
        configuration.isStored ? configuration.statusTint : Color.secondary
      )

      if let link = configuration.link, let linkLabel = configuration.linkLabel {
        Link(destination: link) {
          Label(linkLabel, systemImage: "arrow.up.forward.square")
            .labelStyle(.iconOnly)
        }
        .speakTooltip("Open \(configuration.title)'s site to manage your API key.")
        .accessibilityLabel(linkLabel)
      }

      Spacer(minLength: 0)
    }
  }

  private func compactAPIKeySaveButton(_ configuration: APIKeyCardConfiguration) -> some View {
    Button(action: configuration.onSave) {
      if isValidationInFlight(configuration.validationState) {
        ProgressView()
          .controlSize(.small)
      } else {
        Label(configuration.saveButtonTitle, systemImage: "arrow.down.circle")
          .labelStyle(.iconOnly)
      }
    }
    .disabled(configuration.isSaveDisabled)
    .buttonStyle(.borderedProminent)
    .tint(configuration.tint)
    .speakTooltip(configuration.saveTooltip)
    .accessibilityLabel(configuration.saveButtonTitle)
  }

  @ViewBuilder
  private func compactAPIKeyValidateButton(_ configuration: APIKeyCardConfiguration) -> some View {
    if let onValidate = configuration.onValidate, configuration.isStored {
      Button(action: onValidate) {
        if isValidationInFlight(configuration.validationState) {
          ProgressView()
            .controlSize(.small)
        } else {
          Label(configuration.validateButtonTitle, systemImage: "checkmark.shield")
            .labelStyle(.iconOnly)
        }
      }
      .disabled(configuration.isValidateDisabled)
      .buttonStyle(.bordered)
      .speakTooltip(configuration.validateTooltip)
      .accessibilityLabel(configuration.validateButtonTitle)
    }
  }

  @ViewBuilder
  private func compactAPIKeyRemoveButton(_ configuration: APIKeyCardConfiguration) -> some View {
    if let onRemove = configuration.onRemove, configuration.isStored {
      Button(role: .destructive, action: onRemove) {
        Label(configuration.removeButtonTitle, systemImage: "trash")
          .labelStyle(.iconOnly)
      }
      .disabled(configuration.isRemoveDisabled)
      .buttonStyle(.bordered)
      .speakTooltip(configuration.removeTooltip)
      .accessibilityLabel(configuration.removeButtonTitle)
    }
  }

  private func regularAPIKeyCardBody(_ configuration: APIKeyCardConfiguration) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        Label(configuration.statusLabel, systemImage: configuration.statusIcon)
          .foregroundStyle(
            configuration.isStored ? configuration.statusTint : Color.secondary
          )
          .labelStyle(.titleAndIcon)
        statusBadge(isStored: configuration.isStored, color: configuration.statusTint)
      }

      if let link = configuration.link, let linkLabel = configuration.linkLabel {
        Link(destination: link) {
          Label(linkLabel, systemImage: "arrow.up.forward.square")
            .font(.caption)
        }
        .speakTooltip("Open \(configuration.title)'s site to create or manage your API key.")
      }

      SecureField(configuration.keyFieldLabel, text: configuration.keyBinding)
        .textContentType(.password)
        .privacySensitive()
        .textFieldStyle(.roundedBorder)
        .speakTooltip("Paste the key exactly as issued; Speak stores it securely in your Keychain.")

      Text(configuration.descriptionText)
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 12) {
        regularAPIKeySaveButton(configuration)
        regularAPIKeyValidateButton(configuration)
        regularAPIKeyRemoveButton(configuration)
      }

      validationStatusView(for: configuration.validationState)
      validationDebugDetails(for: configuration.validationState)
    }
  }

  private func regularAPIKeySaveButton(_ configuration: APIKeyCardConfiguration) -> some View {
    Button(action: configuration.onSave) {
      if isValidationInFlight(configuration.validationState) {
        ProgressView()
          .controlSize(.small)
      } else {
        Label(configuration.saveButtonTitle, systemImage: "arrow.down.circle")
      }
    }
    .disabled(configuration.isSaveDisabled)
    .buttonStyle(.borderedProminent)
    .tint(configuration.tint)
    .speakTooltip(configuration.saveTooltip)
  }

  @ViewBuilder
  private func regularAPIKeyValidateButton(_ configuration: APIKeyCardConfiguration) -> some View {
    if let onValidate = configuration.onValidate, configuration.isStored {
      Button(action: onValidate) {
        if isValidationInFlight(configuration.validationState) {
          ProgressView()
            .controlSize(.small)
        } else {
          Label(configuration.validateButtonTitle, systemImage: "checkmark.shield")
        }
      }
      .disabled(configuration.isValidateDisabled)
      .buttonStyle(.bordered)
      .speakTooltip(configuration.validateTooltip)
    }
  }

  @ViewBuilder
  private func regularAPIKeyRemoveButton(_ configuration: APIKeyCardConfiguration) -> some View {
    if let onRemove = configuration.onRemove, configuration.isStored {
      Button(configuration.removeButtonTitle, role: .destructive, action: onRemove)
        .disabled(configuration.isRemoveDisabled)
        .speakTooltip(configuration.removeTooltip)
    }
  }

  private struct CloudKitKeySyncSettingsCard: View {
    let secureStorage: SecureAppStorage
    @ObservedObject private var keySync = CloudKitKeySync.shared
    @State private var passphrase = ""
    @State private var syncError: String?

    var body: some View {
      SettingsCard(title: "Encrypted API-Key Sync", systemImage: "lock.icloud", tint: .brandLagoon) {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Label("Status", systemImage: keySync.status.isEnabled ? "checkmark.seal.fill" : "lock.fill")
            Spacer()
            Text(keySync.status.message)
              .foregroundStyle(keySync.status.isEnabled ? .green : .secondary)
          }

          if !keySync.status.isEnabled {
            SecureField("Sync passphrase", text: $passphrase)
              .textContentType(.password)
              .privacySensitive()
              .textFieldStyle(.roundedBorder)

            Button {
              Task {
                do {
                  try await keySync.enable(passphrase: passphrase)
                  passphrase = ""
                  syncError = nil
                } catch {
                  syncError = error.localizedDescription
                }
              }
            } label: {
              Label("Enable API-Key Sync", systemImage: "lock.open")
            }
            .disabled(passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.borderedProminent)
          } else {
            HStack {
              Button {
                Task {
                  do {
                    try await keySync.syncNow()
                    syncError = nil
                  } catch {
                    syncError = error.localizedDescription
                  }
                }
              } label: {
                Label("Sync Keys Now", systemImage: "arrow.triangle.2.circlepath")
              }
              .disabled(keySync.status.isSyncing)

              Button("Disable", role: .destructive) {
                Task { await keySync.disable() }
              }
            }
          }

          if let syncError {
            Text(syncError)
              .font(.caption)
              .foregroundStyle(.red)
          }

          Text(
            "Opt in to sync API keys through your private CloudKit database. Keys are encrypted with "
              + "CryptoKit before upload. Sync is available when this app is signed into iCloud and "
              + "CloudKit is available."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .task {
        let coreStorage = await secureStorage.coreStorage()
        await keySync.configure(secureStorage: coreStorage)
        _ = await keySync.isAvailable()
      }
    }
  }

  private struct LocalKeychainStorageCard: View {
    var body: some View {
      SettingsCard(title: "Local Keychain Storage", systemImage: "key.fill", tint: .brandLagoon) {
        VStack(alignment: .leading, spacing: 8) {
          Label("Stored locally on this Mac", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
          Text(
            "API keys stay in the macOS Keychain for this direct-download build. "
              + "Encrypted CloudKit API-key sync is available only in App Store builds."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func binding(for providerID: String) -> Binding<String> {
    Binding(
      get: { providerAPIKeys[providerID] ?? "" },
      set: { providerAPIKeys[providerID] = $0 }
    )
  }

  private func statusBadge(isStored: Bool, color: Color) -> some View {
    let text = isStored ? "Saved" : "Not Set"
    let displayColor = isStored ? color : Color.secondary
    return Text(text.uppercased())
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(displayColor.opacity(0.15))
      )
      .foregroundStyle(displayColor)
  }

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

  private func checkProviderKeyValidity(_ provider: TranscriptionProviderMetadata) {
    providerValidationStates[provider.id] = .validating

    Task {
      let registry = TranscriptionProviderRegistry.shared
      guard let providerInstance = await registry.provider(withID: provider.id) else {
        await MainActor.run {
          providerValidationStates[provider.id] =
            .finished(.failure(message: "Provider not found"))
        }
        return
      }

      // Get the stored key
      guard let storedKey = try? await environment.secureStorage.secret(identifier: provider.apiKeyIdentifier) else {
        await MainActor.run {
          providerValidationStates[provider.id] =
            .finished(.failure(message: "API key not found in Keychain"))
        }
        return
      }

      let result = await providerInstance.validateAPIKey(storedKey)

      await MainActor.run {
        providerValidationStates[provider.id] = .finished(result)
      }
    }
  }

  private func saveProviderAPIKey(_ provider: TranscriptionProviderMetadata) {
    guard let value = providerAPIKeys[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return }

    providerValidationStates[provider.id] = .validating

    Task {
      let registry = TranscriptionProviderRegistry.shared
      guard let providerInstance = await registry.provider(withID: provider.id) else {
        await MainActor.run {
          providerValidationStates[provider.id] =
            .finished(.failure(message: "Provider not found"))
        }
        return
      }

      let validation = await providerInstance.validateAPIKey(value)

      switch validation.outcome {
      case .success:
        do {
          try await environment.secureStorage.storeSecret(
            value,
            identifier: provider.apiKeyIdentifier,
            label: provider.apiKeyLabel
          )

          let result = validation.updatingOutcome(
            .success(message: "API key saved and validated successfully")
          )

          await MainActor.run {
            providerAPIKeys[provider.id] = ""
            providerValidationStates[provider.id] = .finished(result)
          }
        } catch {
          let failure = APIKeyValidationResult.failure(
            message: "Failed to store key: \(error.localizedDescription)",
            debug: validation.debug
          )
          await MainActor.run {
            providerValidationStates[provider.id] = .finished(failure)
          }
        }
      case .failure:
        await MainActor.run {
          providerValidationStates[provider.id] = .finished(validation)
        }
      }
    }
  }

  private func removeProviderAPIKey(_ provider: TranscriptionProviderMetadata) {
    Task {
      do {
        try await environment.secureStorage.removeSecret(identifier: provider.apiKeyIdentifier)
        await MainActor.run {
          providerAPIKeys[provider.id] = ""
          providerValidationStates[provider.id] = .idle
        }
      } catch {
        // Handle error silently
      }
    }
  }

  // MARK: - TTS Provider API Key Management

  private func ttsBinding(for providerID: String) -> Binding<String> {
    Binding(
      get: { ttsProviderAPIKeys[providerID] ?? "" },
      set: { ttsProviderAPIKeys[providerID] = $0 }
    )
  }

  private func saveTTSProviderAPIKey(_ provider: TTSProvider) {
    guard let value = ttsProviderAPIKeys[provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return }

    ttsProviderValidationStates[provider.rawValue] = .validating

    Task {
      let client = environment.tts.clients[provider]
      guard let client = client else {
        await MainActor.run {
          ttsProviderValidationStates[provider.rawValue] =
            .finished(.failure(message: "TTS provider not found"))
        }
        return
      }

      let validation = await client.validateAPIKey(value)

      switch validation.outcome {
      case .success:
        do {
          try await environment.secureStorage.storeSecret(
            value,
            identifier: provider.apiKeyIdentifier,
            label: provider.sharesTranscriptionCredential
              ? "\(provider.displayName) API Key"
              : "\(provider.displayName) TTS API Key"
          )

          let result = validation.updatingOutcome(
            .success(message: "API key saved and validated successfully")
          )

          await MainActor.run {
            ttsProviderAPIKeys[provider.rawValue] = ""
            ttsProviderValidationStates[provider.rawValue] = .finished(result)
          }
        } catch {
          let failure = APIKeyValidationResult.failure(
            message: "Failed to store key: \(error.localizedDescription)",
            debug: validation.debug
          )
          await MainActor.run {
            ttsProviderValidationStates[provider.rawValue] = .finished(failure)
          }
        }
      case .failure:
        await MainActor.run {
          ttsProviderValidationStates[provider.rawValue] = .finished(validation)
        }
      }
    }
  }

  private func checkTTSProviderKeyValidity(_ provider: TTSProvider) {
    ttsProviderValidationStates[provider.rawValue] = .validating

    Task {
      let client = environment.tts.clients[provider]
      guard let client = client else {
        await MainActor.run {
          ttsProviderValidationStates[provider.rawValue] =
            .finished(.failure(message: "TTS provider not found"))
        }
        return
      }

      guard let storedKey = try? await environment.secureStorage.secret(identifier: provider.apiKeyIdentifier) else {
        await MainActor.run {
          ttsProviderValidationStates[provider.rawValue] =
            .finished(.failure(message: "API key not found in Keychain"))
        }
        return
      }

      let result = await client.validateAPIKey(storedKey)

      await MainActor.run {
        ttsProviderValidationStates[provider.rawValue] = .finished(result)
      }
    }
  }

  private func removeTTSProviderAPIKey(_ provider: TTSProvider) {
    // Shared credentials also power live transcription; drop cached controllers
    // before the key disappears so no stale session can keep using it.
    if provider.sharesTranscriptionCredential {
      environment.transcription.invalidateLiveControllerCache()
    }
    Task {
      do {
        try await environment.secureStorage.removeSecret(identifier: provider.apiKeyIdentifier)
        await MainActor.run {
          ttsProviderAPIKeys[provider.rawValue] = ""
          ttsProviderValidationStates[provider.rawValue] = .idle
        }
      } catch {
        // Handle error silently
      }
    }
  }

  /// Shared removal helper for the ElevenLabs credential.
  /// Invalidates the live controller cache before clearing Keychain and UI state
  /// so no stale ElevenLabs session can be reused after removal (fail-safe ordering).
  private func removeElevenLabsAPIKey() {
    // Invalidate first — must happen before any Keychain or UI state mutation
    environment.transcription.invalidateLiveControllerCache()
    Task {
      do {
        try await environment.secureStorage.removeSecret(
          identifier: TTSProvider.elevenlabs.apiKeyIdentifier
        )
        await MainActor.run {
          ttsProviderAPIKeys[TTSProvider.elevenlabs.rawValue] = ""
          ttsProviderValidationStates[TTSProvider.elevenlabs.rawValue] = .idle
        }
      } catch {
        // Handle error silently
      }
    }
  }

  private func checkOpenRouterKeyValidity() {
    apiKeyValidationState = .validating

    Task {
      do {
        let storedKey = try await environment.secureStorage.secret(identifier: openRouterKeyIdentifier)
        let result = await environment.openRouter.validateAPIKey(storedKey)

        await MainActor.run {
          apiKeyValidationState = .finished(result)
        }
      } catch {
        await MainActor.run {
          apiKeyValidationState = .finished(
            .failure(message: error.localizedDescription)
          )
        }
      }
    }
  }

  private func removeOpenRouterKey() {
    Task {
      do {
        try await environment.secureStorage.removeSecret(identifier: openRouterKeyIdentifier)
        await MainActor.run {
          apiKeyValidationState = .idle
          newAPIKeyValue = ""
        }
      } catch {
        await MainActor.run {
          apiKeyValidationState = .finished(
            .failure(message: error.localizedDescription)
          )
        }
      }
    }
  }

  @ViewBuilder
  private func validationStatusView(
    for state: ValidationViewState,
    successFallback: String = "Key saved and validated"
  ) -> some View {
    switch state {
    case .idle:
      EmptyView()
    case .validating:
      Text("Validating key…")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .finished(let result):
      switch result.outcome {
      case .success(let message):
        Label(message.isEmpty ? successFallback : message, systemImage: "checkmark.seal")
          .font(.caption)
          .foregroundStyle(.green)
      case .failure(let message):
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private func validationDebugDetails(for state: ValidationViewState) -> some View {
    if case .finished(let result) = state, let debug = result.debug {
      Divider()
        .padding(.vertical, 4)
      APIKeyValidationDebugDetailsView(debug: debug)
    }
  }

  private func isValidationInFlight(_ state: ValidationViewState) -> Bool {
    if case .validating = state { return true }
    return false
  }
}
