import Foundation

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
    permissions: PermissionsManager
  ) -> [TroubleshootingItem]
}

// MARK: - Built-in Checks

struct HotkeyInfoCheck: TroubleshootingCheck {
  @MainActor func evaluate(
    settings: AppSettings,
    permissions: PermissionsManager
  ) -> [TroubleshootingItem] {
    let style = settings.hotKeyActivationStyle
    let detail: String
    switch style {
    case .holdToRecord:
      detail = "Press and hold the Fn key to record. Release to stop."
    case .doubleTapToggle:
      detail = "Double-tap the Fn key to start recording, double-tap again to stop."
    case .holdAndDoubleTap:
      detail = "Hold the Fn key to record (release to stop), or double-tap to toggle."
    }
    return [
      TroubleshootingItem(
        id: "hotkey-info",
        title: "Shortcut: Fn Key",
        detail: detail,
        status: .info,
        systemImage: "keyboard",
        actions: [.navigate(.shortcuts)]
      ),
    ]
  }
}

struct ClipboardRestoreCheck: TroubleshootingCheck {
  @MainActor func evaluate(
    settings: AppSettings,
    permissions: PermissionsManager
  ) -> [TroubleshootingItem] {
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
    permissions: PermissionsManager
  ) -> [TroubleshootingItem] {
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

// MARK: - Analyser

@MainActor
final class TroubleshootingAnalyser: ObservableObject {
  @Published private(set) var items: [TroubleshootingItem] = []

  private let checks: [TroubleshootingCheck] = [
    PermissionsCheck(),
    HotkeyInfoCheck(),
    ClipboardRestoreCheck(),
  ]

  func analyse(settings: AppSettings, permissions: PermissionsManager) {
    let results = checks.flatMap { $0.evaluate(settings: settings, permissions: permissions) }
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
