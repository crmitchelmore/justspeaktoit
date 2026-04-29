import CoreAudio
import Foundation

struct AudioInputDeviceSessionTracker {
  struct Context: Equatable {
    let id: UUID
    let participatesInSharedSession: Bool
  }

  private var activeSessionIDs: Set<UUID> = []
  private var previousDeviceID: AudioDeviceID?
  private var didChangeDevice = false

  var hasActiveSession: Bool {
    !self.activeSessionIDs.isEmpty
  }

  mutating func beginSession(
    previousDeviceID: AudioDeviceID?,
    didChangeDevice: Bool,
    id: UUID = UUID()
  ) -> Context {
    let participatesInSharedSession = didChangeDevice || self.hasActiveSession

    if participatesInSharedSession {
      if self.activeSessionIDs.isEmpty {
        self.previousDeviceID = previousDeviceID
        self.didChangeDevice = didChangeDevice
      }
      self.activeSessionIDs.insert(id)
    }

    return Context(
      id: id,
      participatesInSharedSession: participatesInSharedSession
    )
  }

  mutating func endSession(_ context: Context) -> AudioDeviceID? {
    guard context.participatesInSharedSession else { return nil }
    self.activeSessionIDs.remove(context.id)
    guard self.activeSessionIDs.isEmpty else { return nil }

    let deviceToRestore = self.didChangeDevice ? self.previousDeviceID : nil
    self.previousDeviceID = nil
    self.didChangeDevice = false
    return deviceToRestore
  }
}
