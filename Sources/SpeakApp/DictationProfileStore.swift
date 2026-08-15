import Foundation
import SpeakCore
import os.log

/// Persists the user's per-app dictation profiles as Codable JSON in
/// `UserDefaults`, following the AppSettings storage convention.
@MainActor
final class DictationProfileStore: ObservableObject {
  static let defaultsKey = "dictationProfiles"

  @Published var profiles: [DictationProfile] {
    didSet { persist() }
  }

  private let defaults: UserDefaults
  private let log = SpeakLogger.logger(category: "DictationProfileStore")

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.defaultsKey),
      let decoded = try? DictationProfile.decodeList(data) {
      profiles = decoded
    } else {
      profiles = []
    }
  }

  func upsert(_ profile: DictationProfile) {
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
  }

  func remove(id: UUID) {
    profiles.removeAll { $0.id == id }
  }

  private func persist() {
    if profiles.isEmpty {
      defaults.removeObject(forKey: Self.defaultsKey)
      return
    }
    do {
      defaults.set(try DictationProfile.encodeList(profiles), forKey: Self.defaultsKey)
    } catch {
      log.error("Failed to persist dictation profiles: \(error.localizedDescription)")
    }
  }
}
