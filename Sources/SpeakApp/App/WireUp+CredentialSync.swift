import Foundation
import SpeakCore
import SpeakSync

private let logger = SpeakLogger.logger(category: "WireUp")

/// Encrypted API-key sync through the user's private CloudKit database.
extension WireUp {
  static func startCredentialKeySync(secureStorage: SecureAppStorage) {
    Task {
      let coreStorage = await secureStorage.coreStorage()
      let keySync = CloudKitKeySync.shared
      await keySync.configure(secureStorage: coreStorage)
      guard await keySync.isAvailable() else { return }
      do {
        try await keySync.syncNow()
      } catch {
        logger.error("CloudKit API-key sync failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
