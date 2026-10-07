import Foundation

/// A setting the user can change so a transcript that just failed to reach its
/// destination (or reached a different one than they expected) would have been
/// delivered. Delivery messages append `hint`, and the menu bar offers
/// `menuTitle` to make the change in one click.
enum DeliverySettingsRemedy: Equatable {
  /// Pick a different answer to "If you switch apps before the transcript is
  /// ready". Carries the option that would have delivered this transcript.
  case useAppSwitchDelivery(AppSettings.AppSwitchDelivery)
  /// Direct insertion needs Accessibility access.
  case grantAccessibilityPermission
  /// Accessibility-only output has no clipboard fallback; Smart does.
  case useSmartTextOutput
  /// The experimental streaming insertion could not finish in this app.
  case disableStreamingInsertion

  /// The settings that decide which remedy, if any, applies.
  struct Configuration: Equatable {
    var appSwitchDelivery: AppSettings.AppSwitchDelivery
    var textOutputMethod: AppSettings.TextOutputMethod
    var streamingInsertionEnabled: Bool

    @MainActor
    init(settings: AppSettings) {
      self.init(
        appSwitchDelivery: settings.appSwitchDelivery,
        textOutputMethod: settings.textOutputMethod,
        streamingInsertionEnabled: settings.streamingInsertionEnabled
      )
    }

    init(
      appSwitchDelivery: AppSettings.AppSwitchDelivery,
      textOutputMethod: AppSettings.TextOutputMethod,
      streamingInsertionEnabled: Bool
    ) {
      self.appSwitchDelivery = appSwitchDelivery
      self.textOutputMethod = textOutputMethod
      self.streamingInsertionEnabled = streamingInsertionEnabled
    }
  }

  /// The remedy for a one-shot delivery outcome, or nil when delivery worked
  /// as configured or no setting would have changed the outcome.
  static func forOutput(
    error: Error?,
    warning: Error?,
    focusMovedToOtherApplication: Bool,
    configuration: Configuration
  ) -> DeliverySettingsRemedy? {
    if focusMovedToOtherApplication, configuration.appSwitchDelivery != .currentApp {
      return .useAppSwitchDelivery(.currentApp)
    }
    guard let outputError = (error ?? warning) as? TextOutputError else { return nil }
    switch outputError {
    case .originalApplicationNotInFront:
      return .useAppSwitchDelivery(.originalApp)
    case .targetApplicationUnavailable:
      return configuration.appSwitchDelivery == .currentApp ? nil : .useAppSwitchDelivery(.currentApp)
    case .accessibilityPermissionMissing:
      return .grantAccessibilityPermission
    case .unableToFindFocusedElement, .unableToSetValue, .unableToVerifyInsertion,
      .capturedFieldUnavailable, .capturedFieldChanged:
      return configuration.textOutputMethod == .accessibilityOnly ? .useSmartTextOutput : nil
    case .clipboardWriteFailed, .pasteShortcutUnavailable:
      return nil
    }
  }

  /// The remedy when live insertion into the captured field failed after text
  /// had already been typed there, so the standard delivery could not run.
  static func forLiveInsertionFailure(
    _ error: Error,
    usedStreamingInsertion: Bool,
    configuration: Configuration
  ) -> DeliverySettingsRemedy? {
    if usedStreamingInsertion, configuration.streamingInsertionEnabled {
      return .disableStreamingInsertion
    }
    if let outputError = error as? TextOutputError, case .accessibilityPermissionMissing = outputError {
      return .grantAccessibilityPermission
    }
    return nil
  }

  /// One sentence appended to the HUD/History message telling the user which
  /// setting to change and where.
  var hint: String {
    switch self {
    case .useAppSwitchDelivery(let option):
      return "You can change this: set “\(AppSettings.AppSwitchDelivery.settingName)” to "
        + "“\(option.displayName)” in Settings › General, or from the menu bar."
    case .grantAccessibilityPermission:
      return "Grant Accessibility access in Settings › Permissions, or from the menu bar."
    case .useSmartTextOutput:
      return "Set Text Output to Smart (Auto) in Settings › General, or from the menu bar, "
        + "to paste when direct insertion fails."
    case .disableStreamingInsertion:
      return "Turn off “Stream text while dictating” in Settings › General, or from the menu bar."
    }
  }

  /// The menu bar action that applies the remedy.
  var menuTitle: String {
    switch self {
    case .useAppSwitchDelivery(let option):
      return "When Switching Apps: \(option.displayName)"
    case .grantAccessibilityPermission:
      return "Grant Accessibility Access…"
    case .useSmartTextOutput:
      return "Use Smart (Auto) Text Output"
    case .disableStreamingInsertion:
      return "Turn Off “Stream text while dictating”"
    }
  }

  /// Appends the hint to a delivery message.
  func annotate(_ message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return hint }
    return "\(trimmed) \(hint)"
  }

  @MainActor
  func apply(settings: AppSettings, permissions: PermissionsManager) {
    switch self {
    case .useAppSwitchDelivery(let option):
      settings.appSwitchDelivery = option
    case .grantAccessibilityPermission:
      permissions.openSettings(for: .accessibility)
    case .useSmartTextOutput:
      settings.textOutputMethod = .smart
    case .disableStreamingInsertion:
      settings.streamingInsertionEnabled = false
    }
  }
}

extension Optional where Wrapped == DeliverySettingsRemedy {
  /// The message with the remedy hint appended, or unchanged when there is none.
  func annotate(_ message: String) -> String {
    map { $0.annotate(message) } ?? message
  }
}
