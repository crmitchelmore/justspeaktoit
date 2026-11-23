import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    /// Non-secret local voice studio settings stored in desktop configuration.
    package var voiceStudioConfiguration: VoiceStudioConfiguration {
        settings.configuration?.voiceStudioConfiguration ?? VoiceStudioConfiguration()
    }

    /// Validates and persists non-secret studio configuration to `settings.json`.
    /// API keys are stored separately via `saveVoiceStudioAPIKey(_:for:)`.
    package func saveVoiceStudioConfiguration(_ configuration: VoiceStudioConfiguration) throws {
        guard !closed else { return }
        let trimmedURL = configuration.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            _ = try VoiceStudioEndpointPolicy.validate(
                baseURLString: trimmedURL,
                apiKey: nil,
                requireAPIKeyForRemote: false
            )
        }

        let previous = voiceStudioConfiguration
        var values = settings.configuration?.values ?? [:]
        values[VoiceStudioPreference.enabledKey] = AnyCodable(.bool(configuration.enabled))
        values[VoiceStudioPreference.kindKey] = AnyCodable(.string(configuration.kind.rawValue))
        values[VoiceStudioPreference.baseURLKey] = AnyCodable(.string(trimmedURL))
        values[VoiceStudioPreference.gptSoVITSReferenceAudioPathKey] =
            AnyCodable(.string(configuration.gptSoVITSReferenceAudioPath))
        values[VoiceStudioPreference.gptSoVITSReferencePromptTextKey] =
            AnyCodable(.string(configuration.gptSoVITSReferencePromptText))
        values[VoiceStudioPreference.gptSoVITSReferencePromptLanguageKey] =
            AnyCodable(.string(configuration.gptSoVITSReferencePromptLanguage))
        values[VoiceStudioPreference.gptSoVITSTextLanguageKey] =
            AnyCodable(.string(configuration.gptSoVITSTextLanguage))

        let updatedConfiguration = try DesktopConfiguration(values: values)
        var changed = settings
        changed.configuration = updatedConfiguration
        try effects.writeSettings(
            JSONEncoder().encode(changed),
            to: directory.appendingPathComponent("settings.json")
        )
        settings = changed
        voiceSettingsRevision &+= 1

        if previous.kind != configuration.kind
            || previous.resolvedBaseURLString != configuration.resolvedBaseURLString {
            for kind in VoiceStudioKind.allCases {
                voiceDiscovery.inventories[VoiceAccountProvider(studioKind: kind)] = nil
            }
        }
    }

    /// Stores or removes the optional studio API key in platform secure credential storage only.
    package func saveVoiceStudioAPIKey(_ apiKey: String, for kind: VoiceStudioKind) throws {
        guard !closed else { return }
        let cleaned = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            guard cleaned.utf8.count <= 8_192,
                  cleaned.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else {
                throw VoiceOutputCredentialError.invalidKey
            }
        }
        try Platform.saveAPIKey(cleaned, name: kind.apiKeyCredentialIdentifier)
        recordTrackedAPIKey(kind.apiKeyCredentialIdentifier, value: cleaned)
        voiceDiscovery.inventories[VoiceAccountProvider(studioKind: kind)] = nil
    }

    package func hasVoiceStudioAPIKey(for kind: VoiceStudioKind) -> Bool {
        let key = (try? effects.apiKey(name: kind.apiKeyCredentialIdentifier)) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Probes the configured (or candidate) studio server and reports version, voice count, or readiness.
    package func testVoiceStudioConnection(
        configuration: VoiceStudioConfiguration? = nil,
        apiKeyOverride: String? = nil,
        session: URLSession = .shared
    ) async -> Result<VoiceStudioConnectionResult, VoiceStudioError> {
        let config = configuration ?? voiceStudioConfiguration
        let rawKey = if let apiKeyOverride {
            apiKeyOverride
        } else {
            (try? effects.apiKey(name: config.kind.apiKeyCredentialIdentifier)) ?? ""
        }
        do {
            let result = try await VoiceStudioAPI.testConnection(
                configuration: config,
                apiKey: rawKey,
                session: session
            )
            return .success(result)
        } catch let studioError as VoiceStudioError {
            return .failure(studioError)
        } catch {
            return .failure(.invalidResponse(kind: config.kind, detail: error.localizedDescription))
        }
    }

    /// Lists voices from the configured studio backend and updates the in-memory studio inventory.
    package func refreshVoiceStudioVoices(session: URLSession = .shared) async throws -> VoiceStudioVoiceInventory {
        let config = voiceStudioConfiguration
        guard config.enabled else { throw VoiceStudioError.disabled }
        let apiKey = (try? effects.apiKey(name: config.kind.apiKeyCredentialIdentifier)) ?? ""
        let inventory = try await VoiceStudioAPI.listVoices(
            configuration: config,
            apiKey: apiKey,
            session: session
        )
        voiceDiscovery.inventories[VoiceAccountProvider(studioKind: inventory.kind)] = .studio(inventory)
        return inventory
    }
}
