import Foundation
import SpeakCore

/// Opt-in integrations with paid access, other devices and local automation.
@MainActor
final class IntegrationPreferences: ObservableObject {
  private let persistence: AppSettingsPersistence

  /// Routes transcription and cleanup through the paid subscription service
  /// instead of your own API keys.
  ///
  /// Defaults to `false`, and is additionally ignored unless an entitlement has
  /// actually been verified, so enabling paid access cannot change behaviour for
  /// anyone who has not subscribed.
  @Published var paidAccessRoutingEnabled: Bool {
    didSet { persistence.store(paidAccessRoutingEnabled, key: .paidAccessRoutingEnabled) }
  }

  /// Hides the model pickers and lets the subscription choose the best model
  /// for each task. Only takes effect while paid routing is available.
  @Published var simpleModelChoices: Bool {
    didSet { persistence.store(simpleModelChoices, key: .simpleModelChoices) }
  }

  /// Enable "Send to Mac" transport server
  @Published var enableSendToMac: Bool {
    didSet { persistence.store(enableSendToMac, key: .enableSendToMac) }
  }

  /// Enable the local automation socket used by the `speak` CLI and the bundled
  /// MCP server.
  ///
  /// Off by default and deliberately opt-in: the socket lets any process running
  /// as this user start the microphone and read past transcripts, so it is not a
  /// capability to hand out without the user asking for it.
  @Published var enableAutomationServer: Bool {
    didSet { persistence.store(enableAutomationServer, key: .enableAutomationServer) }
  }

  /// Paste a freshly arrived phone or watch transcript straight at the cursor
  /// instead of only posting a notification with a Paste action (#1007).
  ///
  /// Off by default and deliberately opt-in: text appearing in whatever window
  /// happens to be focused, seconds after a capture the user made on another
  /// device, can overwrite a selection and corrupt a document. The notification
  /// is the safe default, and the paste only ever runs for captures younger
  /// than `RemoteTranscriptArrival.freshnessWindow`.
  @Published var pasteRemoteTranscriptsAtCursor: Bool {
    didSet { persistence.store(pasteRemoteTranscriptsAtCursor, key: .pasteRemoteTranscriptsAtCursor) }
  }

  init(persistence: AppSettingsPersistence) {
    self.persistence = persistence
    // Paid Access — both off by default so existing setups are untouched.
    paidAccessRoutingEnabled = persistence.flag(.paidAccessRoutingEnabled, default: false)
    simpleModelChoices = persistence.flag(.simpleModelChoices, default: false)
    enableSendToMac = persistence.flag(.enableSendToMac, default: false)
    enableAutomationServer = persistence.flag(.enableAutomationServer, default: false)
    pasteRemoteTranscriptsAtCursor = persistence.flag(.pasteRemoteTranscriptsAtCursor, default: false)
  }

  func reload(from restored: IntegrationPreferences) {
    paidAccessRoutingEnabled = restored.paidAccessRoutingEnabled
    simpleModelChoices = restored.simpleModelChoices
    enableSendToMac = restored.enableSendToMac
    enableAutomationServer = restored.enableAutomationServer
    pasteRemoteTranscriptsAtCursor = restored.pasteRemoteTranscriptsAtCursor
  }
}

extension AppSettings {
  var paidAccessRoutingEnabled: Bool {
    get { integrations.paidAccessRoutingEnabled }
    set { integrations.paidAccessRoutingEnabled = newValue }
  }

  var simpleModelChoices: Bool {
    get { integrations.simpleModelChoices }
    set { integrations.simpleModelChoices = newValue }
  }

  var enableSendToMac: Bool {
    get { integrations.enableSendToMac }
    set { integrations.enableSendToMac = newValue }
  }

  var enableAutomationServer: Bool {
    get { integrations.enableAutomationServer }
    set { integrations.enableAutomationServer = newValue }
  }

  var pasteRemoteTranscriptsAtCursor: Bool {
    get { integrations.pasteRemoteTranscriptsAtCursor }
    set { integrations.pasteRemoteTranscriptsAtCursor = newValue }
  }
}
