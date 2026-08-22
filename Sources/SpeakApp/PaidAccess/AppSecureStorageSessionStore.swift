import Foundation
import SpeakCore

/// Bridges the app's `SecureAppStorage` actor to the SpeakCore session store.
///
/// `SecureAppStorage.coreStorage()` is asynchronous, so the underlying store is
/// resolved per call rather than held. That keeps the composition root
/// synchronous and means the session lands in the same Keychain vault as the
/// user's API keys instead of in user defaults.
struct AppSecureStorageSessionStore: PaidAccessSessionStoring {

  private let storage: SecureAppStorage

  init(storage: SecureAppStorage) {
    self.storage = storage
  }

  private func store() async -> KeychainPaidAccessSessionStore {
    KeychainPaidAccessSessionStore(storage: await self.storage.coreStorage())
  }

  func loadSession() async -> PaidAccessSession? {
    await self.store().loadSession()
  }

  func saveSession(_ session: PaidAccessSession) async throws {
    try await self.store().saveSession(session)
  }

  func clearSession() async {
    await self.store().clearSession()
  }
}
