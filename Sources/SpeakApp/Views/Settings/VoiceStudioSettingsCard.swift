import SpeakCore
import SwiftUI

/// Settings card for connecting a local Voicebox, VoiceStudio, or GPT-SoVITS backend.
struct VoiceStudioSettingsCard: View, AppSettingsBindingProviding {
  @EnvironmentObject var environment: AppEnvironment
  @EnvironmentObject var settings: AppSettings
  let onVoicesChanged: () -> Void

  @State private var apiKeyDraft = ""
  @State private var hasStoredAPIKey = false
  @State private var isTestingConnection = false
  @State private var statusMessage: String?
  @State private var statusIsError = false

  private var endpointPolicyWarning: String? {
    do {
      _ = try VoiceStudioEndpointPolicy.validate(
        baseURLString: settings.voiceStudioConfiguration.resolvedBaseURLString,
        apiKey: hasStoredAPIKey ? "configured" : nil
      )
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  var body: some View {
    SettingsCard(title: "Local Voice Studio", systemImage: "waveform.and.mic", tint: Color.teal) {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Enable Local Voice Studio", isOn: settingsBinding(\AppSettings.voiceStudioEnabled))
          .accessibilityLabel("Enable Local Voice Studio")
          .accessibilityIdentifier("settings.voiceStudio.enabled")
          .onChange(of: settings.voiceStudioEnabled) { _, _ in
            onVoicesChanged()
          }

        Picker("Studio", selection: settingsBinding(\AppSettings.voiceStudioKind)) {
          ForEach(VoiceStudioKind.allCases) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Local Voice Studio Backend")
        .accessibilityIdentifier("settings.voiceStudio.kind")

        VStack(alignment: .leading, spacing: 4) {
          TextField(
            "Server URL",
            text: settingsBinding(\AppSettings.voiceStudioBaseURL),
            prompt: Text(settings.voiceStudioKind.defaultBaseURLString)
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Voice Studio Server URL")
          .accessibilityIdentifier("settings.voiceStudio.baseURL")

          Text(
            "Loopback default: \(settings.voiceStudioKind.defaultBaseURLString) · "
              + "\(settings.voiceStudioKind.voiceListEndpointSummary) · "
              + "\(settings.voiceStudioKind.speechEndpointSummary)"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        if let endpointPolicyWarning {
          Text(endpointPolicyWarning)
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("settings.voiceStudio.securityWarning")
        }

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            SecureField(
              "API Key (optional on localhost, required for remote HTTPS)",
              text: $apiKeyDraft
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Voice Studio API Key")
            .accessibilityIdentifier("settings.voiceStudio.apiKey")

            Button("Save Key") {
              Task { await saveAPIKey() }
            }
            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Save Voice Studio API Key")
            .accessibilityIdentifier("settings.voiceStudio.saveKey")

            if hasStoredAPIKey {
              Button("Remove Key") {
                Task { await removeAPIKey() }
              }
              .accessibilityLabel("Remove Voice Studio API Key")
              .accessibilityIdentifier("settings.voiceStudio.removeKey")
            }
          }

          Text(
            hasStoredAPIKey
              ? "An API key for \(settings.voiceStudioKind.displayName) is saved in Keychain."
              : "No API key stored in Keychain for \(settings.voiceStudioKind.displayName)."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        if settings.voiceStudioKind == .gptSoVITS {
          gptSoVITSFields
        }

        HStack(spacing: 8) {
          Button(isTestingConnection ? "Testing…" : "Test Connection") {
            Task { await testConnection() }
          }
          .disabled(isTestingConnection)
          .accessibilityLabel("Test Voice Studio Connection")
          .accessibilityIdentifier("settings.voiceStudio.testConnection")

          if settings.voiceStudioKind.supportsVoiceDiscovery {
            Button("Refresh Voices") {
              onVoicesChanged()
            }
            .disabled(!settings.voiceStudioEnabled)
            .accessibilityLabel("Refresh Voice Studio Voices")
            .accessibilityIdentifier("settings.voiceStudio.refreshVoices")
          }
        }

        if let statusMessage {
          Text(statusMessage)
            .font(.caption)
            .foregroundStyle(statusIsError ? Color.orange : Color.secondary)
            .accessibilityIdentifier("settings.voiceStudio.status")
        }
      }
    }
    .speakTooltip("Connect Voicebox, VoiceStudio, or GPT-SoVITS over HTTP(S) as a Read Aloud voice source.")
    .task(id: settings.voiceStudioKind) {
      hasStoredAPIKey = await environment.secureStorage.hasSecret(
        identifier: settings.voiceStudioKind.apiKeyCredentialIdentifier
      )
    }
  }

  @ViewBuilder
  private var gptSoVITSFields: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        "Reference Audio Clip Path",
        text: settingsBinding(\AppSettings.voiceStudioGPTSoVITSReferenceAudioPath),
        prompt: Text("/path/to/reference.wav")
      )
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("GPT-SoVITS Reference Audio Clip Path")
      .accessibilityIdentifier("settings.voiceStudio.gptSoVITS.referenceAudioPath")

      TextField(
        "Reference Prompt Text",
        text: settingsBinding(\AppSettings.voiceStudioGPTSoVITSReferencePromptText),
        prompt: Text("Transcript spoken in the reference clip")
      )
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("GPT-SoVITS Reference Prompt Text")
      .accessibilityIdentifier("settings.voiceStudio.gptSoVITS.referencePromptText")

      HStack(spacing: 12) {
        Picker(
          "Prompt Language",
          selection: settingsBinding(\AppSettings.voiceStudioGPTSoVITSPromptLanguage)
        ) {
          ForEach(VoiceStudioPreference.gptSoVITSSupportedLanguages, id: \.code) { language in
            Text(language.label).tag(language.code)
          }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("GPT-SoVITS Reference Prompt Language")
        .accessibilityIdentifier("settings.voiceStudio.gptSoVITS.promptLanguage")

        Picker("Output Language", selection: settingsBinding(\AppSettings.voiceStudioGPTSoVITSTextLanguage)) {
          ForEach(VoiceStudioPreference.gptSoVITSSupportedLanguages, id: \.code) { language in
            Text(language.label).tag(language.code)
          }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("GPT-SoVITS Output Language")
        .accessibilityIdentifier("settings.voiceStudio.gptSoVITS.textLanguage")
      }
    }
  }

  private func saveAPIKey() async {
    let cleaned = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    do {
      try await environment.secureStorage.storeSecret(
        cleaned,
        identifier: settings.voiceStudioKind.apiKeyCredentialIdentifier
      )
      apiKeyDraft = ""
      hasStoredAPIKey = true
      statusIsError = false
      statusMessage = "Saved API key in Keychain for \(settings.voiceStudioKind.displayName)."
      onVoicesChanged()
    } catch {
      statusIsError = true
      statusMessage = "Failed to save Keychain API key: \(error.localizedDescription)"
    }
  }

  private func removeAPIKey() async {
    do {
      try await environment.secureStorage.removeSecret(
        identifier: settings.voiceStudioKind.apiKeyCredentialIdentifier
      )
      hasStoredAPIKey = false
      statusIsError = false
      statusMessage = "Removed Keychain API key for \(settings.voiceStudioKind.displayName)."
      onVoicesChanged()
    } catch {
      statusIsError = true
      statusMessage = "Failed to remove Keychain API key: \(error.localizedDescription)"
    }
  }

  func testConnection() async {
    isTestingConnection = true
    defer { isTestingConnection = false }

    let draftKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let storedKey = try? await environment.secureStorage.secret(
      identifier: settings.voiceStudioKind.apiKeyCredentialIdentifier
    )
    let effectiveKey = draftKey.isEmpty ? storedKey : draftKey

    do {
      let result = try await VoiceStudioAPI.testConnection(
        configuration: settings.voiceStudioConfiguration,
        apiKey: effectiveKey
      )
      statusIsError = false
      statusMessage = result.detailMessage
      onVoicesChanged()
    } catch {
      statusIsError = true
      statusMessage = error.localizedDescription
    }
  }
}
