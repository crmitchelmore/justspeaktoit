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
    !activeSessionIDs.isEmpty
  }

  mutating func beginSession(
    previousDeviceID: AudioDeviceID?,
    didChangeDevice: Bool,
    id: UUID = UUID()
  ) -> Context {
    let participatesInSharedSession = didChangeDevice || hasActiveSession

    if participatesInSharedSession {
      if activeSessionIDs.isEmpty {
        self.previousDeviceID = previousDeviceID
        self.didChangeDevice = didChangeDevice
      }
      activeSessionIDs.insert(id)
    }

    return Context(
      id: id,
      participatesInSharedSession: participatesInSharedSession
    )
  }

  mutating func endSession(_ context: Context) -> AudioDeviceID? {
    guard context.participatesInSharedSession else { return nil }
    activeSessionIDs.remove(context.id)
    guard activeSessionIDs.isEmpty else { return nil }

    let deviceToRestore = didChangeDevice ? previousDeviceID : nil
    previousDeviceID = nil
    didChangeDevice = false
    return deviceToRestore
  }
}
