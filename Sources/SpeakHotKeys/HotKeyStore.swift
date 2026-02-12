import Combine
import Foundation
import os.log

/// Persists the selected hotkey binding to UserDefaults.
@MainActor
public final class HotKeyStore: ObservableObject {
  /// The currently stored hotkey. Defaults to `.fnKey`.
  @Published public var hotKey: HotKey {
    didSet { save() }
  }

  private let defaultsKey: String
  private let log = Logger(subsystem: "com.justspeaktoit.hotkeys", category: "HotKeyStore")

  /// - Parameter defaultsKey: UserDefaults key to persist the binding under.
  public init(defaultsKey: String = "com.justspeaktoit.hotkeys.selectedHotKey") {
    self.defaultsKey = defaultsKey
    self.hotKey = .fnKey
    self.hotKey = load()
  }

  private func load() -> HotKey {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode(HotKey.self, from: data)
    else {
      return .fnKey
    }
    log.debug("Loaded hotkey: \(decoded.displayString)")
    return decoded
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(hotKey) else { return }
    UserDefaults.standard.set(data, forKey: defaultsKey)
    log.debug("Saved hotkey: \(self.hotKey.displayString)")
  }
}
