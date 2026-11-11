import Foundation
import SpeakCore
import SpeakHotKeys

// MARK: - Troubleshooting Item Model

typealias TroubleshootingStatus = DesktopTroubleshooting.Severity

enum TroubleshootingAction {
  case navigate(SettingsTab)
  case autoFix(title: String, @MainActor () async throws -> Void)
}

private struct TroubleshootingFixError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
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
    let hotKey = settings.selectedHotKey
    var items: [TroubleshootingItem] = []

    // Fn-specific troubleshooting
    if hotKey == .fnKey {
      items.append(
        TroubleshootingItem(
          id: "hotkey-fn-tip",
          title: "Fn Key Tip",
          // swiftlint:disable:next line_length
          detail: "If Fn opens the emoji picker, go to System Settings → Keyboard → \"Press 🌐 key to\" and change it to \"Do Nothing\". External keyboards may not send Fn — consider using a custom shortcut instead.",
          status: .info,
          systemImage: "globe",
          actions: [.navigate(.shortcuts)]
        )
      )
      if !permissions.status(for: .inputMonitoring).isGranted {
        items.append(
          TroubleshootingItem(
            id: "hotkey-fn-permission",
            title: "Fn Shortcut Needs Input Monitoring",
            detail: "Grant Input Monitoring so Speak can detect the Fn key while another app is active.",
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

struct ConfigurationTroubleshootingCheck: TroubleshootingCheck {
  @MainActor func evaluate(
    settings: AppSettings,
    permissions: PermissionsManager,
    secureStorage: SecureAppStorage
  ) async -> [TroubleshootingItem] {
    let model = ModelCatalog.resolvedPostProcessingModel(settings.postProcessingModel)
    let enabled = settings.postProcessingEnabled
    let keyName = settings.selectedHotKey.displayString
    let restore = settings.restoreClipboardAfterPaste
    let instructions: String
    switch settings.hotKeyActivationStyle {
    case .holdToRecord:
      instructions = "Press and hold \(keyName) to record. Release to stop."
    case .doubleTapToggle:
      instructions = "Double-tap \(keyName) to start recording, double-tap again to stop."
    case .holdAndDoubleTap:
      instructions = "Hold \(keyName) to record (release to stop), or double-tap to toggle."
    }
    let credential: DesktopTroubleshooting.Credential
    if DesktopTroubleshooting.requiresCredential(enabled: enabled, model: model) {
      credential = await Self.credentialState {
        try await secureStorage.secret(identifier: "openrouter.apiKey")
      }
    } else {
      credential = .available
    }
    let input = DesktopTroubleshooting.Input(
      postProcessing: .init(enabled: enabled, model: model, credential: credential),
      shortcutName: keyName, shortcutInstructions: instructions, restoreClipboard: restore
    )
    return DesktopTroubleshooting.findings(input).map {
      self.item($0, settings: settings, secureStorage: secureStorage, input: input)
    }
  }

  @MainActor private func item(
    _ finding: DesktopTroubleshooting.Finding, settings: AppSettings,
    secureStorage: SecureAppStorage, input: DesktopTroubleshooting.Input
  ) -> TroubleshootingItem {
    let tab: SettingsTab
    switch finding.destination {
    case .general: tab = .general
    case .apiKeys: tab = .apiKeys
    case .shortcuts: tab = .shortcuts
    case .permissions: tab = .permissions
    }
    var actions: [TroubleshootingAction] = []
    if let fix = finding.fix {
      actions.append(.autoFix(title: fix.title) {
        try await self.apply(fix, settings: settings, input: input) {
          try await secureStorage.secret(identifier: "openrouter.apiKey")
        }
      })
    }
    actions.append(.navigate(tab))
    return TroubleshootingItem(
      id: finding.id, title: finding.title, detail: finding.detail,
      status: finding.severity, systemImage: finding.systemImage, actions: actions
    )
  }

  @MainActor static func credentialState(
    _ readSecret: @MainActor () async throws -> String
  ) async -> DesktopTroubleshooting.Credential {
    do {
      let key = try await readSecret()
      return key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .available
    } catch SecureAppStorageError.valueNotFound {
      return .missing
    } catch {
      return .unavailable
    }
  }

  @MainActor func apply(
    _ fix: DesktopTroubleshooting.Fix, settings: AppSettings, input: DesktopTroubleshooting.Input,
    readSecret: @MainActor () async throws -> String
  ) async throws {
    switch fix {
    case .keepTranscriptOnClipboard:
      guard settings.restoreClipboardAfterPaste == input.restoreClipboard else {
        throw TroubleshootingFixError(message: "Text output changed. Check again before applying this fix.")
      }
      settings.restoreClipboardAfterPaste = false
    case .disablePostProcessing:
      try requireProcessingSnapshot(settings, expected: input.postProcessing)
      let credential = await Self.credentialState(readSecret)
      try requireProcessingSnapshot(settings, expected: input.postProcessing)
      switch credential {
      case .missing: settings.postProcessingEnabled = false
      case .available:
        throw TroubleshootingFixError(message: "A key is now available. Check again before disabling cleanup.")
      case .unavailable:
        throw TroubleshootingFixError(message: "The saved credential could not be read. No setting was changed.")
      }
    }
  }

  @MainActor private func requireProcessingSnapshot(
    _ settings: AppSettings, expected: DesktopTroubleshooting.PostProcessing
  ) throws {
    guard settings.postProcessingEnabled == expected.enabled,
          ModelCatalog.resolvedPostProcessingModel(settings.postProcessingModel) == expected.model else {
      throw TroubleshootingFixError(message: "Post-processing changed. Check again before applying this fix.")
    }
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

// MARK: - Analyser

@MainActor
final class TroubleshootingAnalyser: ObservableObject {
  @Published private(set) var items: [TroubleshootingItem] = []
  private var revision = 0

  private let checks: [TroubleshootingCheck] = [
    PermissionsCheck(),
    ConfigurationTroubleshootingCheck(),
    HotkeyInfoCheck()
  ]

  func analyse(settings: AppSettings, permissions: PermissionsManager, secureStorage: SecureAppStorage) async {
    revision += 1
    let expectedRevision = revision
    var results: [TroubleshootingItem] = []
    for check in checks {
      let items = await check.evaluate(settings: settings, permissions: permissions, secureStorage: secureStorage)
      guard expectedRevision == revision, !Task.isCancelled else { return }
      results.append(contentsOf: items)
    }
    items = results.sorted { $0.status.priority < $1.status.priority }
  }
}
