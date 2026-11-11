import SpeakCore
import SwiftUI

/// Whether a key check is running or what it last reported.
enum APIKeyValidationViewState {
  case idle
  case validating
  case finished(APIKeyValidationResult)

  var isInFlight: Bool {
    if case .validating = self { return true }
    return false
  }

  /// Whether the last check failed, which the Errors filter shows.
  var hasFailed: Bool {
    guard case .finished(let result) = self, case .failure = result.outcome else { return false }
    return true
  }
}

/// The API Keys tab's drafts and validation states, and the save, check and
/// remove actions that move a key between the form and the Keychain.
@MainActor
final class APIKeyFormModel: ObservableObject {
  static let openRouterKeyIdentifier = "openrouter.apiKey"

  @Published var openRouterDraft = ""
  @Published var openRouterState: APIKeyValidationViewState = .idle
  @Published var providerDrafts: [String: String] = [:]
  @Published var providerStates: [String: APIKeyValidationViewState] = [:]
  @Published var ttsDrafts: [String: String] = [:]
  @Published var ttsStates: [String: APIKeyValidationViewState] = [:]

  /// Provider credit balances shown beside the saved keys. Deduplicated by
  /// account, so one account is fetched and displayed once however many cards
  /// its key powers.
  let balances = ProviderBalanceStore()

  var isValidatingOpenRouterKey: Bool { openRouterState.isInFlight }

  func saveOpenRouterKey(in environment: AppEnvironment) {
    openRouterState = .validating
    let value = openRouterDraft.trimmingCharacters(in: .whitespacesAndNewlines)

    Task {
      let validation = await environment.openRouter.validateAPIKey(value)

      switch validation.outcome {
      case .success:
        do {
          try await environment.secureStorage.storeSecret(
            value,
            identifier: Self.openRouterKeyIdentifier,
            label: "OpenRouter API Key"
          )

          let result = validation.updatingOutcome(
            .success(message: "Key saved and validated")
          )

          await MainActor.run {
            openRouterState = .finished(result)
            openRouterDraft = ""
          }
        } catch {
          let failure = APIKeyValidationResult.failure(
            message: "Failed to store key: \(error.localizedDescription)",
            debug: validation.debug
          )
          await MainActor.run {
            openRouterState = .finished(failure)
          }
        }
      case .failure:
        await MainActor.run {
          openRouterState = .finished(validation)
        }
      }
    }
  }

  func checkOpenRouterKey(in environment: AppEnvironment) {
    openRouterState = .validating

    Task {
      do {
        let storedKey = try await environment.secureStorage.secret(identifier: Self.openRouterKeyIdentifier)
        let result = await environment.openRouter.validateAPIKey(storedKey)

        await MainActor.run {
          openRouterState = .finished(result)
        }
      } catch {
        await MainActor.run {
          openRouterState = .finished(
            .failure(message: error.localizedDescription)
          )
        }
      }
    }
  }

  func removeOpenRouterKey(in environment: AppEnvironment) {
    Task {
      do {
        try await environment.secureStorage.removeSecret(identifier: Self.openRouterKeyIdentifier)
        await MainActor.run {
          openRouterState = .idle
          openRouterDraft = ""
        }
      } catch {
        await MainActor.run {
          openRouterState = .finished(
            .failure(message: error.localizedDescription)
          )
        }
      }
    }
  }

  /// Re-reads the account balance after its credential changes, so a replaced
  /// key never leaves the previous account's figure on screen.
  private func refreshBalance(forCredentialIdentifier identifier: String) {
    guard let account = ProviderBalanceDirectory.account(forCredentialIdentifier: identifier) else { return }
    balances.refresh(accountID: account.id)
  }

  func providerDraft(for providerID: String) -> Binding<String> {
    Binding(
      get: { self.providerDrafts[providerID] ?? "" },
      set: { self.providerDrafts[providerID] = $0 }
    )
  }

  func checkProviderKey(_ provider: TranscriptionProviderMetadata, in environment: AppEnvironment) {
    providerStates[provider.id] = .validating

    Task {
      let registry = TranscriptionProviderRegistry.shared
      guard let providerInstance = await registry.provider(withID: provider.id) else {
        await MainActor.run {
          providerStates[provider.id] =
            .finished(.failure(message: "Provider not found"))
        }
        return
      }

      // Get the stored key
      guard let storedKey = try? await environment.secureStorage.secret(identifier: provider.apiKeyIdentifier) else {
        await MainActor.run {
          providerStates[provider.id] =
            .finished(.failure(message: "API key not found in Keychain"))
        }
        return
      }

      let result = await providerInstance.validateAPIKey(storedKey)

      await MainActor.run {
        providerStates[provider.id] = .finished(result)
      }
    }
  }

  // Keep the configuration capture, validation and secure write in one save lifecycle.
  // swiftlint:disable:next function_body_length
  func saveProviderKey(_ provider: TranscriptionProviderMetadata, in environment: AppEnvironment) {
    guard let enteredValue = providerDrafts[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !enteredValue.isEmpty
    else { return }

    let value: String
    do {
      value = provider.id == "alibaba"
        ? try AlibabaSpeechConfiguration.credentialsForSaving(enteredValue) : enteredValue
    } catch {
      providerStates[provider.id] = .finished(.failure(message: error.localizedDescription))
      return
    }
    providerStates[provider.id] = .validating

    Task {
      let registry = TranscriptionProviderRegistry.shared
      guard let providerInstance = await registry.provider(withID: provider.id) else {
        await MainActor.run {
          providerStates[provider.id] =
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
            .success(message: provider.id == "alibaba"
              ? "Alibaba key, region and workspace saved. Access is checked when transcribing."
              : "API key saved and validated successfully")
          )

          await MainActor.run {
            providerDrafts[provider.id] = ""
            providerStates[provider.id] = .finished(result)
            refreshBalance(forCredentialIdentifier: provider.apiKeyIdentifier)
          }
        } catch {
          let failure = APIKeyValidationResult.failure(
            message: "Failed to store key: \(error.localizedDescription)",
            debug: validation.debug
          )
          await MainActor.run {
            providerStates[provider.id] = .finished(failure)
          }
        }
      case .failure:
        await MainActor.run {
          providerStates[provider.id] = .finished(validation)
        }
      }
    }
  }

  func removeProviderKey(_ provider: TranscriptionProviderMetadata, in environment: AppEnvironment) {
    Task {
      do {
        try await environment.secureStorage.removeSecret(identifier: provider.apiKeyIdentifier)
        await MainActor.run {
          providerDrafts[provider.id] = ""
          providerStates[provider.id] = .idle
        }
      } catch {
        // Handle error silently
      }
    }
  }
}

// MARK: - Native cleanup keys

extension APIKeyFormModel {
  static func nativeTextStateID(_ provider: NativeTextProvider) -> String { "text-\(provider.id)" }

  /// Cleanup-only providers have no speech validator, so the key is stored as entered
  /// and checked by the first cleanup request.
  func saveNativeTextKey(_ provider: NativeTextProvider, in environment: AppEnvironment) {
    let stateID = Self.nativeTextStateID(provider)
    guard let value = providerDrafts[stateID]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return }
    providerStates[stateID] = .validating
    Task {
      do {
        try await environment.secureStorage.storeSecret(
          value, identifier: provider.credentialIdentifier, label: "\(provider.displayName) API Key"
        )
        await MainActor.run {
          providerDrafts[stateID] = ""
          providerStates[stateID] = .finished(.success(message: "API key saved"))
        }
      } catch {
        await MainActor.run {
          providerStates[stateID] = .finished(
            .failure(message: "Failed to store key: \(error.localizedDescription)")
          )
        }
      }
    }
  }

  func removeNativeTextKey(_ provider: NativeTextProvider, in environment: AppEnvironment) {
    let stateID = Self.nativeTextStateID(provider)
    Task {
      try? await environment.secureStorage.removeSecret(identifier: provider.credentialIdentifier)
      await MainActor.run {
        providerDrafts[stateID] = ""
        providerStates[stateID] = .idle
      }
    }
  }
}

// MARK: - Voice-output keys

extension APIKeyFormModel {
  func ttsDraft(for providerID: String) -> Binding<String> {
    Binding(
      get: { self.ttsDrafts[providerID] ?? "" },
      set: { self.ttsDrafts[providerID] = $0 }
    )
  }

  func saveTTSKey(_ provider: TTSProvider, in environment: AppEnvironment) {
    guard let value = ttsDrafts[provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return }

    // Drop cached controllers before the replacement lands, so a cached session
    // cannot keep using the key the user has just replaced.
    invalidateSharedTranscriptionCache(for: provider, in: environment)

    ttsStates[provider.rawValue] = .validating

    Task {
      let client = environment.tts.clients[provider]
      guard let client = client else {
        await MainActor.run {
          ttsStates[provider.rawValue] =
            .finished(.failure(message: "TTS provider not found"))
        }
        return
      }

      let validation = await client.validateAPIKey(value)

      switch validation.outcome {
      case .success(let message):
        do {
          try await environment.secureStorage.storeSecret(
            value,
            identifier: provider.apiKeyIdentifier,
            label: provider.sharesTranscriptionCredential
              ? "\(provider.displayName) API Key"
              : "\(provider.displayName) TTS API Key"
          )

          let result = validation.updatingOutcome(
            .success(message: "API key saved. \(message)")
          )

          await MainActor.run {
            // Validation and storage take a network round trip. A session that
            // started inside that window cached a controller built from the old
            // key, so the cache is dropped again now the replacement is stored.
            invalidateSharedTranscriptionCache(for: provider, in: environment)
            ttsDrafts[provider.rawValue] = ""
            ttsStates[provider.rawValue] = .finished(result)
            refreshBalance(forCredentialIdentifier: provider.apiKeyIdentifier)
          }
        } catch {
          let failure = APIKeyValidationResult.failure(
            message: "Failed to store key: \(error.localizedDescription)",
            debug: validation.debug
          )
          await MainActor.run {
            ttsStates[provider.rawValue] = .finished(failure)
          }
        }
      case .failure:
        await MainActor.run {
          ttsStates[provider.rawValue] = .finished(validation)
        }
      }
    }
  }

  func checkTTSKey(_ provider: TTSProvider, in environment: AppEnvironment) {
    ttsStates[provider.rawValue] = .validating

    Task {
      let client = environment.tts.clients[provider]
      guard let client = client else {
        await MainActor.run {
          ttsStates[provider.rawValue] =
            .finished(.failure(message: "TTS provider not found"))
        }
        return
      }

      guard let storedKey = try? await environment.secureStorage.secret(identifier: provider.apiKeyIdentifier) else {
        await MainActor.run {
          ttsStates[provider.rawValue] =
            .finished(.failure(message: "API key not found in Keychain"))
        }
        return
      }

      let result = await client.validateAPIKey(storedKey)

      await MainActor.run {
        ttsStates[provider.rawValue] = .finished(result)
      }
    }
  }

  /// Drops cached live controllers when this provider's key also powers
  /// transcription, so no cached session can keep using a superseded key.
  private func invalidateSharedTranscriptionCache(for provider: TTSProvider, in environment: AppEnvironment) {
    guard provider.sharesTranscriptionCredential else { return }
    environment.transcription.invalidateLiveControllerCache()
  }

  func removeTTSKey(_ provider: TTSProvider, in environment: AppEnvironment) {
    // Drop cached controllers before the key disappears, so no stale session
    // can keep using it.
    invalidateSharedTranscriptionCache(for: provider, in: environment)
    Task {
      do {
        try await environment.secureStorage.removeSecret(identifier: provider.apiKeyIdentifier)
        await MainActor.run {
          ttsDrafts[provider.rawValue] = ""
          ttsStates[provider.rawValue] = .idle
        }
      } catch {
        // Handle error silently
      }
    }
  }
}
