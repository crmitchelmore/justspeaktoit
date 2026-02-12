import Foundation
import SpeakHotKeys

// MARK: - Troubleshooting Item Model

enum TroubleshootingStatus {
  case ok
  case info
  case warning
  case issue
}

enum TroubleshootingAction {
  case navigate(SettingsTab)
  case autoFix(() -> Void)
}

struct TroubleshootingItem: Identifiable {
  let id: String
  let title: String
  let detail: String
  let status: TroubleshootingStatus
  let systemImage: String
  let actions: [TroubleshootingAction]
}

// MARK: - Check Protocol

protocol TroubleshootingCheck {
  @MainActor func evaluate(
    settings: AppSettings,
    permissions: PermissionsManager,
    secureStorage: SecureAppStorage
  ) async -> [TroubleshootingItem]
}

// MARK: - Built-in Checks

struct HotkeyInfoCheck: TroubleshootingCheck {
  @MainActor func evaluate(
    settings: AppSettings,
    permissions: PermissionsManager,
    secureStorage: SecureAppStorage
  ) async -> [TroubleshootingItem] {
    let style = settings.hotKeyActivationStyle
    let hotKey = settings.selectedHotKey
    let keyName = hotKey.displayString
    
    let detail: String
    switch style {
    case .holdToRecord:
      detail = "Press and hold \(keyName) to record. Release to stop."
    case .doubleTapToggle:
      detail = "Double-tap \(keyName) to start recording, double-tap again to stop."
    case .holdAndDoubleTap:
      detail = "Hold \(keyName) to record (release to stop), or double-tap to toggle."
    }
    
    var items = [
      TroubleshootingItem(
        id: "hotkey-info",
        title: "Shortcut: \(keyName)",
        detail: detail,
        status: .info,
        systemImage: "keyboard",
        actions: [.navigate(.shortcuts)]
      ),
    ]
    
    // Fn-specific troubleshooting
    if hotKey == .fnKey {
      items.append(
        TroubleshootingItem(
          id: "hotkey-fn-tip",
          title: "Fn Key Tip",
          detail: "If Fn opens the emoji picker, go to System Settings → Keyboard → \"Press 🌐 key to\" and change it to \"Do Nothing\". External keyboards may not send Fn — consider using a custom shortcut instead.",
          status: .info,
          systemImage: "globe",
          actions: [.navigate(.shortcuts)]
        )
      )
    }
    
    // Custom shortcut troubleshooting
    if case .custom = hotKey {
      let accessibilityGranted = permissions.status(for: .accessibility).isGranted
      let inputMonitoringGranted = permissions.status(for: .inputMonitoring).isGranted
      if !accessibilityGranted || !inputMonitoringGranted {
        items.append(
          TroubleshootingItem(
            id: "hotkey-custom-permissions",
            title: "Custom Shortcut Needs Permissions",
            detail: "Custom hotkey detection requires both Accessibility and Input Monitoring permissions. Grant them in System Settings → Privacy & Security.",
            status: .issue,
            systemImage: "lock.shield",
            actions: [.navigate(.permissions)]
          )
        )
      }
    }
    
    return items
  }
}

struct ClipboardRestoreCheck: TroubleshootingCheck {
  @MainActor func evaluate(
    settings: AppSettings,
    permissions: PermissionsManager,
    secureStorage: SecureAppStorage
  ) async -> [TroubleshootingItem] {
    guard settings.restoreClipboardAfterPaste else {
      return [
        TroubleshootingItem(
          id: "clipboard-restore",
          title: "Clipboard Behaviour",
          detail: "Transcriptions are kept on your clipboard after pasting.",
          status: .ok,
          systemImage: "doc.on.clipboard",
          actions: [.navigate(.general)]
        ),
      ]
    }
    return [
      TroubleshootingItem(
        id: "clipboard-restore",
        title: "Clipboard Is Restored After Paste",
        detail:
          "Your clipboard is restored to its previous contents after pasting. If you want to keep transcriptions on your clipboard, turn this off.",
        status: .warning,
        systemImage: "doc.on.clipboard",
        actions: [
          .autoFix { settings.restoreClipboardAfterPaste = false },
          .navigate(.general),
        ]
      ),
    ]
  }
}

struct PermissionsCheck: TroubleshootingCheck {
  @MainActor func evaluate(
    settings: AppSettings,
    permissions: PermissionsManager,
    secureStorage: SecureAppStorage
  ) async -> [TroubleshootingItem] {
    permissions.refreshAll()
    return PermissionType.allCases.compactMap { type in
      let status = permissions.status(for: type)
      guard !status.isGranted else { return nil }
      let troubleStatus: TroubleshootingStatus =
        status == .denied ? .issue : .warning
      return TroubleshootingItem(
        id: "permission-\(type.id)",
        title: "\(type.displayName) Permission Required",
        detail: type.guidanceText,
        status: troubleStatus,
        systemImage: type.systemIconName,
        actions: [.navigate(.permissions)]
      )
    }
  }
}

struct PostProcessingAPIKeyCheck: TroubleshootingCheck {
  @MainActor func evaluate(
    settings: AppSettings,
    permissions: PermissionsManager,
    secureStorage: SecureAppStorage
  ) async -> [TroubleshootingItem] {
    guard settings.postProcessingEnabled else {
      return []
    }

    let model = settings.postProcessingModel
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedModel = model.isEmpty ? "inception/mercury" : model
    let isLocal = resolvedModel.lowercased().hasPrefix("apple/")
      || resolvedModel.lowercased().hasPrefix("local/")
      || resolvedModel.lowercased() == "on-device"

    guard !isLocal else { return [] }

    let hasKey = await secureStorage.hasSecret(identifier: "openrouter.apiKey")
    if hasKey { return [] }

    return [
      TroubleshootingItem(
        id: "postprocessing-api-key",
        title: "Post-Processing Needs an API Key",
        detail:
          "Post-processing is enabled and uses \(resolvedModel), which requires an OpenRouter API key. Add one in API Keys, or disable post-processing if you don't need it.",
        status: .issue,
        systemImage: "key",
        actions: [
          .autoFix { settings.postProcessingEnabled = false },
          .navigate(.apiKeys),
        ]
      ),
    ]
  }
}

// MARK: - Analyser

@MainActor
final class TroubleshootingAnalyser: ObservableObject {
  @Published private(set) var items: [TroubleshootingItem] = []

  private let checks: [TroubleshootingCheck] = [
    PermissionsCheck(),
    PostProcessingAPIKeyCheck(),
    HotkeyInfoCheck(),
    ClipboardRestoreCheck(),
  ]

  func analyse(settings: AppSettings, permissions: PermissionsManager, secureStorage: SecureAppStorage) async {
    var results: [TroubleshootingItem] = []
    for check in checks {
      let items = await check.evaluate(settings: settings, permissions: permissions, secureStorage: secureStorage)
      results.append(contentsOf: items)
    }
    items = results.sorted { priority($0.status) < priority($1.status) }
  }

  private func priority(_ status: TroubleshootingStatus) -> Int {
    switch status {
    case .issue: return 0
    case .warning: return 1
    case .info: return 2
    case .ok: return 3
    }
  }
}
