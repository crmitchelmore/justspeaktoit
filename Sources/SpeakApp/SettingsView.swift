import AppKit
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
  case general
  case transcription
  case postProcessing
  case apiKeys
  case hotKeys
  case permissions

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .transcription: return "Transcription"
    case .postProcessing: return "Post-processing"
    case .apiKeys: return "API Keys"
    case .hotKeys: return "Hotkeys"
    case .permissions: return "Permissions"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject private var settings: AppSettings
  @State private var selectedTab: SettingsTab = .general
  @State private var newAPIKeyValue: String = ""
  @State private var apiKeyValidationState: ValidationState = .idle
  @State private var isDeletingRecordings: Bool = false
  @State private var lastValidationDebug: OpenRouterValidationDebugSnapshot?
  @State private var transcriptionProviders: [TranscriptionProviderMetadata] = []
  @State private var providerAPIKeys: [String: String] = [:]
  @State private var validatingProviders: Set<String> = []
  @State private var providerValidationStates: [String: ProviderValidationState] = [:]
  private let openRouterKeyIdentifier = "openrouter.apiKey"

  enum ValidationState {
    case idle
    case validating
    case success
    case failure(String)
  }

  enum ProviderValidationState {
    case idle
    case validating
    case success(String) // Success message
    case failure(String) // Error message
  }

  private var isOpenRouterKeyStored: Bool {
    settings.trackedAPIKeyIdentifiers.contains(openRouterKeyIdentifier)
  }

  private var isValidatingKey: Bool {
    if case .validating = apiKeyValidationState { return true }
    return false
  }

  private var overviewHeader: some View {
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
          title: "Mode", value: settings.transcriptionMode.displayName, systemImage: "waveform")
        overviewChip(
          title: "Post-processing",
          value: settings.postProcessingEnabled ? "Enabled" : "Disabled",
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

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
    case .general:
      generalSettings
    case .transcription:
      transcriptionSettings
    case .postProcessing:
      postProcessingSettings
    case .apiKeys:
      apiKeySettings
    case .hotKeys:
      hotKeySettings
    case .permissions:
      permissionsSettings
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

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        overviewHeader

        Picker("Settings", selection: $selectedTab) {
          ForEach(SettingsTab.allCases) { tab in
            Text(tab.title).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 6)

        tabContent
      }
      .padding(24)
      .frame(maxWidth: 1100, alignment: .center)
    }
    .background(
      LinearGradient(
        colors: [Color.orange.opacity(0.08), .clear], startPoint: .top, endPoint: .center))
    .task {
      transcriptionProviders = await TranscriptionProviderRegistry.shared.allProviders()
    }
  }

  private var generalSettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "Appearance", systemImage: "paintpalette", tint: Color.purple) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose how Speak looks across light, dark, or system themes.")
            .font(.callout)
            .foregroundStyle(.secondary)
          Picker("Theme", selection: settingsBinding(\AppSettings.appearance)) {
            ForEach(AppSettings.Appearance.allCases) { appearance in
              Text(appearance.rawValue.capitalized).tag(appearance)
            }
          }
          .pickerStyle(.segmented)
        }
      }

      SettingsCard(title: "Output", systemImage: "textformat.alt", tint: Color.blue) {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Text Output", selection: settingsBinding(\AppSettings.textOutputMethod)) {
            ForEach(AppSettings.TextOutputMethod.allCases) { method in
              Text(method.displayName).tag(method)
            }
          }
          .pickerStyle(.menu)

          Toggle(
            "Restore clipboard after paste",
            isOn: settingsBinding(\AppSettings.restoreClipboardAfterPaste)
          )
          .tint(.blue)
          Toggle(
            "Show HUD during sessions", isOn: settingsBinding(\AppSettings.showHUDDuringSessions))
          .tint(.blue)
          Toggle("Show status bar only", isOn: settingsBinding(\AppSettings.showStatusBarOnly))
          .tint(.blue)
          Toggle("Launch at login", isOn: settingsBinding(\AppSettings.runAtLogin))
          .tint(.blue)
        }
      }

      SettingsCard(title: "Housekeeping", systemImage: "tray.full", tint: Color.orange) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder")
              .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
              Text("Recordings directory")
                .font(.headline)
              Text(settings.recordingsDirectory.path)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal") {
              NSWorkspace.shared.activateFileViewerSelecting([
                settings.recordingsDirectory
              ])
            }
            .buttonStyle(.bordered)
          }

          Button {
            isDeletingRecordings = true
            Task {
              let recordings = await environment.audio.listRecordings()
              for recording in recordings {
                await environment.audio.removeRecording(at: recording.url)
              }
              await MainActor.run { isDeletingRecordings = false }
            }
          } label: {
            Label("Delete all recordings", systemImage: "trash")
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(isDeletingRecordings)
        }
      }
    }
  }

  private var transcriptionSettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "Transcription mode", systemImage: "waveform", tint: Color.teal) {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Transcription Mode", selection: settingsBinding(\AppSettings.transcriptionMode)) {
            ForEach(AppSettings.TranscriptionMode.allCases) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          .pickerStyle(.segmented)

          TextField(
            "Preferred Locale (e.g. en_US)",
            text: settingsBinding(\AppSettings.preferredLocaleIdentifier)
          )
          .textFieldStyle(.roundedBorder)
        }
      }

      SettingsCard(title: "Recording buffer", systemImage: "waveform.path.ecg", tint: Color.cyan) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Keep recording for a moment after you let go to capture trailing words.")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Slider(
              value: settingsBinding(\AppSettings.postRecordingTailDuration),
              in: 0...2,
              step: 0.1
            )
            Text(
              settings.postRecordingTailDuration,
              format: .number.precision(.fractionLength(1))
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Text("sec")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      SettingsCard(title: "Live transcription", systemImage: "mic.fill", tint: Color.indigo) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Model used while recording continuously on-device.")
            .font(.caption)
            .foregroundStyle(.secondary)
          ModelPicker(
            title: "On-device Model",
            help: "These engines never leave your Mac and respond immediately.",
            options: ModelCatalog.liveTranscription,
            value: settingsBinding(\AppSettings.liveTranscriptionModel)
          )
        }
      }

      SettingsCard(
        title: "Batch transcription", systemImage: "folder.badge.clock", tint: Color.cyan
      ) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Model used when we upload the recording after it finishes.")
            .font(.caption)
            .foregroundStyle(.secondary)
          ModelPicker(
            title: "Batch Model",
            help: "Remote transcription runs after recording stops.",
            options: ModelCatalog.batchTranscription,
            value: settingsBinding(\AppSettings.batchTranscriptionModel)
          )
        }
      }
    }
  }

  private var postProcessingSettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "Cleanup", systemImage: "wand.and.stars", tint: Color.pink) {
        VStack(alignment: .leading, spacing: 12) {
          Toggle(
            "Enable Post-processing", isOn: settingsBinding(\AppSettings.postProcessingEnabled))
          .tint(.pink)

          ModelPicker(
            title: "Post-processing Model",
            help: "We clean up the transcript before delivery using this model.",
            options: ModelCatalog.postProcessing,
            value: settingsBinding(\AppSettings.postProcessingModel)
          )

          VStack(alignment: .leading) {
            HStack {
              Text("Temperature")
              Spacer()
              Text(
                settings.postProcessingTemperature,
                format: .number.precision(.fractionLength(2))
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
            Slider(
              value: settingsBinding(\AppSettings.postProcessingTemperature), in: 0...1, step: 0.05)
          }
        }
      }

      SettingsCard(title: "System prompt", systemImage: "quote.bubble", tint: Color.mint) {
        VStack(alignment: .leading, spacing: 8) {
          Text("The system prompt guides how the LLM cleans up your transcript.")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextEditor(text: settingsBinding(\AppSettings.postProcessingSystemPrompt))
            .font(.body.monospaced())
            .frame(minHeight: 200)
            .overlay(
              RoundedRectangle(cornerRadius: 12)
                .stroke(Color.mint.opacity(0.2), lineWidth: 1)
            )
        }
      }
    }
  }

  private var apiKeySettings: some View {
    LazyVStack(spacing: 20) {
      // OpenRouter (Legacy)
      SettingsCard(title: "OpenRouter", systemImage: "network", tint: Color.green) {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .center, spacing: 12) {
            Label("Status", systemImage: isOpenRouterKeyStored ? "checkmark.seal.fill" : "key.fill")
              .foregroundStyle(isOpenRouterKeyStored ? Color.green : Color.secondary)
              .labelStyle(.titleAndIcon)
            openRouterStatusBadge
          }

          SecureField("OpenRouter API Key", text: $newAPIKeyValue)
            .textContentType(.password)
            .privacySensitive()
            .textFieldStyle(.roundedBorder)

          Text("Stored securely in your macOS Keychain. We only use it when calling OpenRouter.")
            .font(.caption)
            .foregroundStyle(.secondary)

          HStack(spacing: 12) {
            Button(action: saveAPIKey) {
              if isValidatingKey {
                ProgressView()
              } else {
                Label(
                  isOpenRouterKeyStored ? "Replace Key" : "Save Key",
                  systemImage: "arrow.down.circle")
              }
            }
            .disabled(
              isValidatingKey
                || newAPIKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .buttonStyle(.borderedProminent)

            if isOpenRouterKeyStored {
              Button {
                checkOpenRouterKeyValidity()
              } label: {
                Label("Check Validity", systemImage: "checkmark.shield")
              }
              .disabled(isValidatingKey)
              .buttonStyle(.bordered)

              Button("Remove Key", role: .destructive) {
                removeOpenRouterKey()
              }
              .disabled(isValidatingKey)
            }
          }

          validationStatusView
          validationDebugDetails
        }
      }

      // Transcription Providers (Dynamic)
      ForEach(transcriptionProviders) { provider in
        providerAPIKeyCard(for: provider)
      }
    }
  }

  private func providerAPIKeyCard(for provider: TranscriptionProviderMetadata) -> some View {
    let isStored = settings.trackedAPIKeyIdentifiers.contains(provider.apiKeyIdentifier)
    let isValidating = validatingProviders.contains(provider.id)
    let tintColor = colorFromString(provider.tintColor)
    let validationState = providerValidationStates[provider.id] ?? .idle

    return SettingsCard(title: provider.displayName, systemImage: provider.systemImage, tint: tintColor) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center, spacing: 12) {
          Label("Status", systemImage: isStored ? "checkmark.seal.fill" : "key.fill")
            .foregroundStyle(isStored ? tintColor : Color.secondary)
            .labelStyle(.titleAndIcon)
          statusBadge(isStored: isStored, color: tintColor)
        }

        if !provider.website.isEmpty {
          Link(destination: URL(string: provider.website)!) {
            Label("Get API Key", systemImage: "arrow.up.forward.square")
              .font(.caption)
          }
        }

        SecureField(provider.apiKeyLabel, text: binding(for: provider.id))
          .textContentType(.password)
          .privacySensitive()
          .textFieldStyle(.roundedBorder)

        Text("Stored securely in your macOS Keychain. Used only for \(provider.displayName) transcription.")
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 12) {
          Button {
            saveProviderAPIKey(provider)
          } label: {
            if isValidating {
              ProgressView()
                .controlSize(.small)
            } else {
              Label(
                isStored ? "Replace Key" : "Save Key",
                systemImage: "arrow.down.circle")
            }
          }
          .disabled(
            isValidating
              || (providerAPIKeys[provider.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
          .buttonStyle(.borderedProminent)
          .tint(tintColor)

          if isStored {
            Button {
              checkProviderKeyValidity(provider)
            } label: {
              if case .validating = validationState {
                ProgressView()
                  .controlSize(.small)
              } else {
                Label("Check Validity", systemImage: "checkmark.shield")
              }
            }
            .disabled(isValidating || isValidatingProviderKey(validationState))
            .buttonStyle(.bordered)

            Button("Remove Key", role: .destructive) {
              removeProviderAPIKey(provider)
            }
            .disabled(isValidating)
          }
        }

        providerValidationStatusView(for: provider.id, state: validationState)
      }
    }
  }

  private func binding(for providerID: String) -> Binding<String> {
    Binding(
      get: { providerAPIKeys[providerID] ?? "" },
      set: { providerAPIKeys[providerID] = $0 }
    )
  }

  private func isValidatingProviderKey(_ state: ProviderValidationState) -> Bool {
    if case .validating = state {
      return true
    }
    return false
  }

  private func statusBadge(isStored: Bool, color: Color) -> some View {
    let text = isStored ? "Saved" : "Not Set"
    return Text(text.uppercased())
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(color.opacity(0.15))
      )
      .foregroundStyle(color)
  }

  private func colorFromString(_ name: String) -> Color {
    switch name.lowercased() {
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "orange": return .orange
    case "red": return .red
    case "pink": return .pink
    case "yellow": return .yellow
    case "cyan": return .cyan
    case "indigo": return .indigo
    case "mint": return .mint
    case "teal": return .teal
    default: return .accentColor
    }
  }

  @ViewBuilder
  private func providerValidationStatusView(for providerID: String, state: ProviderValidationState) -> some View {
    switch state {
    case .idle:
      EmptyView()
    case .validating:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text("Validating key...")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .success(let message):
      Label(message, systemImage: "checkmark.seal")
        .font(.caption)
        .foregroundStyle(.green)
    case .failure(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private func checkProviderKeyValidity(_ provider: TranscriptionProviderMetadata) {
    providerValidationStates[provider.id] = .validating

    Task {
      let registry = TranscriptionProviderRegistry.shared
      guard let providerInstance = await registry.provider(withID: provider.id) else {
        await MainActor.run {
          providerValidationStates[provider.id] = .failure("Provider not found")
        }
        return
      }

      // Get the stored key
      guard let storedKey = try? await environment.secureStorage.secret(identifier: provider.apiKeyIdentifier) else {
        await MainActor.run {
          providerValidationStates[provider.id] = .failure("API key not found in keychain")
        }
        return
      }

      let isValid = await providerInstance.validateAPIKey(storedKey)

      await MainActor.run {
        if isValid {
          providerValidationStates[provider.id] = .success("API key is valid and working")
        } else {
          providerValidationStates[provider.id] = .failure("API key validation failed")
        }
      }
    }
  }

  private func saveProviderAPIKey(_ provider: TranscriptionProviderMetadata) {
    guard let value = providerAPIKeys[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return }

    validatingProviders.insert(provider.id)
    providerValidationStates[provider.id] = .validating

    Task {
      let registry = TranscriptionProviderRegistry.shared
      guard let providerInstance = await registry.provider(withID: provider.id) else {
        await MainActor.run {
          validatingProviders.remove(provider.id)
          providerValidationStates[provider.id] = .failure("Provider not found")
        }
        return
      }

      let isValid = await providerInstance.validateAPIKey(value)

      if isValid {
        do {
          try await environment.secureStorage.storeSecret(
            value,
            identifier: provider.apiKeyIdentifier,
            label: provider.apiKeyLabel
          )
          await MainActor.run {
            validatingProviders.remove(provider.id)
            providerAPIKeys[provider.id] = ""
            providerValidationStates[provider.id] = .success("API key saved and validated successfully")
          }
        } catch {
          await MainActor.run {
            validatingProviders.remove(provider.id)
            providerValidationStates[provider.id] = .failure("Failed to store key: \(error.localizedDescription)")
          }
        }
      } else {
        await MainActor.run {
          validatingProviders.remove(provider.id)
          providerValidationStates[provider.id] = .failure("API key validation failed. Please check your key.")
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
        }
      } catch {
        // Handle error silently
      }
    }
  }

  private func checkOpenRouterKeyValidity() {
    apiKeyValidationState = .validating
    lastValidationDebug = nil

    Task {
      do {
        let storedKey = try await environment.secureStorage.secret(identifier: openRouterKeyIdentifier)
        let isValid = await environment.openRouter.validateAPIKey(storedKey)
        let debug = await environment.openRouter.latestValidationDebug()

        await MainActor.run {
          if isValid {
            apiKeyValidationState = .success
            lastValidationDebug = debug
          } else {
            apiKeyValidationState = .failure(
              debug?.errorDescription?.isEmpty == false
                ? debug?.errorDescription ?? "Validation failed"
                : "Validation failed"
            )
            lastValidationDebug = debug
          }
        }
      } catch {
        await MainActor.run {
          apiKeyValidationState = .failure(error.localizedDescription)
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
          lastValidationDebug = nil
        }
      } catch {
        await MainActor.run {
          apiKeyValidationState = .failure(error.localizedDescription)
        }
      }
    }
  }

  private var openRouterStatusBadge: some View {
    let color: Color = isOpenRouterKeyStored ? .green : .secondary
    let text = isOpenRouterKeyStored ? "Saved" : "Not Set"
    return Text(text.uppercased())
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(color.opacity(0.15))
      )
      .foregroundStyle(color)
  }

  @ViewBuilder
  private var validationStatusView: some View {
    switch apiKeyValidationState {
    case .idle:
      EmptyView()
    case .validating:
      Text("Validating key…")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .success:
      Label("Key saved and validated", systemImage: "checkmark.seal")
        .font(.caption)
        .foregroundStyle(.green)
    case .failure(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  @ViewBuilder
  private var validationDebugDetails: some View {
    if let debug = lastValidationDebug {
      Divider()
        .padding(.vertical, 4)
      ValidationDebugDetailsView(debug: debug)
    }
  }

  private var hotKeySettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "Activation", systemImage: "command.square", tint: Color.yellow) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Choose how the Fn key controls recording.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Picker("Activation", selection: settingsBinding(\AppSettings.hotKeyActivationStyle)) {
            ForEach(AppSettings.HotKeyActivationStyle.allCases) { style in
              Text(style.displayName).tag(style)
            }
          }
          .pickerStyle(.segmented)
        }
      }

      SettingsCard(title: "Timing", systemImage: "timer", tint: Color.orange) {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("Hold Threshold")
              Spacer()
              Text(
                settings.holdThreshold, format: .number.precision(.fractionLength(2))
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
            Slider(value: settingsBinding(\AppSettings.holdThreshold), in: 0.2...1.5, step: 0.05)
          }

          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("Double Tap Window")
              Spacer()
              Text(
                settings.doubleTapWindow, format: .number.precision(.fractionLength(2))
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
            Slider(value: settingsBinding(\AppSettings.doubleTapWindow), in: 0.2...1.0, step: 0.05)
          }
        }
      }
    }
  }

  private var permissionsSettings: some View {
    LazyVStack(spacing: 20) {
      SettingsCard(title: "System permissions", systemImage: "lock.shield", tint: Color.red) {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(PermissionType.allCases) { permission in
            let status = environment.permissions.status(for: permission)
            HStack(spacing: 12) {
              Label(permission.displayName, systemImage: permission.systemIconName)
              Spacer()
              Text(statusLabel(for: status))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor(status).opacity(0.15), in: Capsule())
                .foregroundStyle(statusColor(status))
              Button("Request") {
                Task { await environment.permissions.request(permission) }
              }
              .buttonStyle(.bordered)
            }
          }

          Button("Refresh Statuses") {
            environment.permissions.refreshAll()
          }
          .buttonStyle(.borderedProminent)
        }
      }
    }
  }

  private func statusLabel(for status: PermissionStatus) -> String {
    switch status {
    case .granted: return "Granted"
    case .denied: return "Denied"
    case .restricted: return "Restricted"
    case .notDetermined: return "Pending"
    }
  }

  private func statusColor(_ status: PermissionStatus) -> Color {
    switch status {
    case .granted: return .green
    case .denied: return .red
    case .restricted: return .orange
    case .notDetermined: return .yellow
    }
  }

  private func saveAPIKey() {
    apiKeyValidationState = .validating
    let value = newAPIKeyValue.trimmingCharacters(in: .whitespacesAndNewlines)

    Task {
      do {
        let isValid = await environment.openRouter.validateAPIKey(value)
        let debug = await environment.openRouter.latestValidationDebug()
        if isValid {
          try await environment.secureStorage.storeSecret(
            value,
            identifier: openRouterKeyIdentifier,
            label: "OpenRouter API Key"
          )
          await MainActor.run {
            apiKeyValidationState = .success
            newAPIKeyValue = ""
            lastValidationDebug = debug
          }
        } else {
          await MainActor.run {
            apiKeyValidationState = .failure(
              debug?.errorDescription?.isEmpty == false
                ? debug?.errorDescription ?? "Validation failed"
                : "Validation failed"
            )
            lastValidationDebug = debug
          }
        }
      } catch {
        let debug = await environment.openRouter.latestValidationDebug()
        await MainActor.run {
          apiKeyValidationState = .failure(error.localizedDescription)
          lastValidationDebug = debug
        }
      }
    }
  }

  private func settingsBinding<Value: Hashable>(
    _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: { settings[keyPath: keyPath] = $0 }
    )
  }
}

private struct SettingsCard<Content: View>: View {
  let title: String
  let systemImage: String
  let tint: Color
  @ViewBuilder let content: Content

  init(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(tint.opacity(0.15))
            .frame(width: 44, height: 44)
          Image(systemName: systemImage)
            .foregroundStyle(tint)
            .font(.system(size: 20, weight: .semibold))
        }

        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
        Spacer()
      }

      content
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .stroke(tint.opacity(0.12), lineWidth: 1)
        .allowsHitTesting(false)
    )
    .shadow(color: tint.opacity(0.08), radius: 18, x: 0, y: 12)
  }
}

private struct ModelPicker: View {
  let title: String
  let help: String?
  let options: [ModelCatalog.Option]
  @Binding var value: String

  @State private var selection: String
  @State private var customValue: String

  init(title: String, help: String? = nil, options: [ModelCatalog.Option], value: Binding<String>) {
    self.title = title
    self.help = help
    self.options = options
    _value = value

    let trimmed = value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = options.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      _selection = State(initialValue: match.id)
      _customValue = State(initialValue: "")
    } else if trimmed.isEmpty, let first = options.first {
      _selection = State(initialValue: first.id)
      _customValue = State(initialValue: "")
      DispatchQueue.main.async {
        value.wrappedValue = first.id
      }
    } else {
      _selection = State(initialValue: ModelCatalog.customOptionID)
      _customValue = State(initialValue: trimmed)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(title, selection: $selection) {
        ForEach(options) { option in
          Text(option.displayName).tag(option.id)
        }
        Text("Custom…").tag(ModelCatalog.customOptionID)
      }
      .pickerStyle(.menu)

      if let help {
        Text(help)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let description = selectedOption?.description {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if selection == ModelCatalog.customOptionID {
        TextField("Custom model identifier", text: $customValue, prompt: Text("provider/model"))
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
      } else {
        HStack(spacing: 6) {
          Image(systemName: "info.circle")
            .imageScale(.small)
            .foregroundStyle(.secondary)
          Text(ModelCatalog.friendlyName(for: value))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .onChange(of: selection) { _, newValue in
      if newValue == ModelCatalog.customOptionID {
        if customValue.isEmpty {
          customValue = value
        }
        value = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        value = newValue
      }
    }
    .onChange(of: customValue) { _, newValue in
      if selection == ModelCatalog.customOptionID {
        value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
  }

  private var selectedOption: ModelCatalog.Option? {
    options.first { option in
      option.id.caseInsensitiveCompare(selection) == .orderedSame
    }
  }
}

private struct ValidationDebugDetailsView: View {
  let debug: OpenRouterValidationDebugSnapshot
  @State private var isExpanded: Bool = true

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 16) {
        debugSection(title: "Request") {
          debugRow(label: "URL", value: debug.url)
          debugRow(label: "Method", value: debug.method)
          if !debug.requestHeaders.isEmpty {
            headersSection(title: "Headers", headers: debug.requestHeaders)
          }
          if let body = debug.requestBody, !body.isEmpty {
            bodySection(title: "Body", value: body)
          }
        }

        debugSection(title: "Response") {
          if let status = debug.statusCode {
            debugRow(label: "Status", value: String(status))
          }
          if !debug.responseHeaders.isEmpty {
            headersSection(title: "Headers", headers: debug.responseHeaders)
          }
          if let body = debug.responseBody, !body.isEmpty {
            bodySection(title: "Body", value: body)
          }
        }

        if let error = debug.errorDescription, !error.isEmpty {
          debugSection(title: "Error") {
            Text(error)
              .font(.caption.monospaced())
              .foregroundStyle(.red)
          }
        }
      }
      .padding(.top, 6)
    } label: {
      Label("Latest validation details", systemImage: "ladybug")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func debugSection<Content: View>(title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func debugRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label + ":")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospaced())
        .foregroundStyle(.primary)
      Spacer()
    }
  }

  @ViewBuilder
  private func headersSection(title: String, headers: [String: String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
          Text("\(entry.key): \(entry.value)")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .padding(8)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  @ViewBuilder
  private func bodySection(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(value, forType: .string)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Copy to clipboard")
      }
      ScrollView(.vertical) {
        Text(value)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 160)
      .padding(8)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}

// @Implement: This view allows management of all settings within the app settings class. Each logical grouping of settings should have it's own segment in a tab bar at the top of the view. All settings should be immediately persisted through the AppSettings class when they are changed. Break down the view in to smaller components for easier management.
// - API key management: This should save to key vault. When a key is added it should validate using an api call. Each key should have red/green indicators to confirm it's saved or not.
// - General configuration (including light/dark mode), delete any caches or audio files. Text Output configuration. Show status bar only/run in background mode but still can open the app from the status bar.
// - Transcription configuration - if it's using a live transcribe with osx native (or select an api to stream to) or if it's batch and will send the file after. And which model to use for each of those and any model configuration
// - Post-processing configuration. System prompt and temperature, model selection, enabled or disabled.
// - Hotkey management and configuration: This should allow selection of a hotkey (default should be the fn key). Probably a https://github.com/sindresorhus/KeyboardShortcuts is a good choice
// - Permission management: Call from permissions manager to see and ask for permissions and allow the user to validate easily for each one if it was correctly granted. Perhaps a test button that tries to use the permission and validates the outcome somehow.
// And then any other sections you think are relevant. This should be presented in a concise but user-friendly format.
