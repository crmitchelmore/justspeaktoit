import SpeakCore
import SwiftUI

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
