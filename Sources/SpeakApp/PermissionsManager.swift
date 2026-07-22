import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import SpeakCore
import Speech

// @Implement This class manages system permissions. It knows how to request the following permissions when asked and also surface the current status of permissions as per the system

enum PermissionType: CaseIterable, Identifiable {
  case microphone
  case speechRecognition
  case accessibility
  case inputMonitoring

  var id: String { displayName }

  static func availablePermissions(for channel: DistributionChannel) -> [PermissionType] {
    allCases.filter { permission in
      permission != .accessibility || channel.supportsAccessibilityTextInsertion
    }
  }

  var displayName: String {
    switch self {
    case .microphone:
      return "Microphone"
    case .speechRecognition:
      return "Speech Recognition"
    case .accessibility:
      return "Accessibility"
    case .inputMonitoring:
      return "Input Monitoring"
    }
  }

  var systemIconName: String {
    switch self {
    case .microphone:
      return "mic"
    case .speechRecognition:
      return "waveform"
    case .accessibility:
      return "accessibility"
    case .inputMonitoring:
      return "keyboard"
    }
  }

  var guidanceText: String {
    switch self {
    case .microphone:
      return "Allow Speak to access your microphone so we can capture your words the moment you press record."
    case .speechRecognition:
      return "Grant macOS speech recognition so Speak can turn your recordings into on-screen text in real time."
    case .accessibility:
      return "Enable accessibility controls so Speak can show helpful overlays and respond to your shortcuts respectfully."
    case .inputMonitoring:
      return "Permit hotkey monitoring so Speak notices only the shortcuts you assign—nothing more."
    }
  }

  var settingsURL: URL {
    switch self {
    case .microphone:
      return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    case .speechRecognition:
      return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
    case .accessibility:
      return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    case .inputMonitoring:
      return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    }
  }

  var manualSetupSteps: [String]? {
    switch self {
    case .accessibility, .inputMonitoring:
      return [
        "Open \(displayName) settings.",
        "Click the + button at the bottom of the app list, or unlock first if macOS asks.",
        "Navigate to Applications → JustSpeakToIt.",
        "Click Open, then enable the toggle."
      ]
    case .microphone, .speechRecognition:
      return nil
    }
  }
}

enum PermissionStatus: Equatable {
  case notDetermined
  case granted
  case denied
  case restricted

  var isGranted: Bool {
    if case .granted = self { return true }
    return false
  }
}

enum PermissionRequestIssue: Equatable {
  case timedOut

  func guidance(for permission: PermissionType) -> String {
    switch self {
    case .timedOut:
      return "macOS did not finish the \(permission.displayName) request. Open System Settings, "
        + "choose a permission state, then refresh Speak."
    }
  }
}

private enum SpeechAuthorizationRequestOutcome {
  case status(PermissionStatus)
  case timedOut
}

private final class SpeechAuthorizationRequestGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<SpeechAuthorizationRequestOutcome, Never>?
  private var resolvedOutcome: SpeechAuthorizationRequestOutcome?

  func install(_ continuation: CheckedContinuation<SpeechAuthorizationRequestOutcome, Never>) {
    lock.lock()
    if let resolvedOutcome {
      lock.unlock()
      continuation.resume(returning: resolvedOutcome)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func resolve(_ outcome: SpeechAuthorizationRequestOutcome) {
    lock.lock()
    guard resolvedOutcome == nil else {
      lock.unlock()
      return
    }
    resolvedOutcome = outcome
    let pendingContinuation = continuation
    continuation = nil
    lock.unlock()
    pendingContinuation?.resume(returning: outcome)
  }
}

@MainActor
final class PermissionsManager: ObservableObject {
  typealias SpeechAuthorizationRequester = (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void

  @Published private(set) var statuses: [PermissionType: PermissionStatus] = [:]
  @Published private(set) var requestIssues: [PermissionType: PermissionRequestIssue] = [:]
  private let statusProvider: (PermissionType) -> PermissionStatus
  private let speechAuthorizationRequester: SpeechAuthorizationRequester
  private let speechAuthorizationTimeout: TimeInterval
  private let notificationCenter: NotificationCenter
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(
    statusProvider: @escaping (PermissionType) -> PermissionStatus = PermissionsManager.systemStatus,
    speechAuthorizationRequester: @escaping SpeechAuthorizationRequester = { callback in
      SFSpeechRecognizer.requestAuthorization(callback)
    },
    speechAuthorizationTimeout: TimeInterval = 8,
    notificationCenter: NotificationCenter = .default
  ) {
    self.statusProvider = statusProvider
    self.speechAuthorizationRequester = speechAuthorizationRequester
    self.speechAuthorizationTimeout = speechAuthorizationTimeout
    self.notificationCenter = notificationCenter
    refreshAll()
    registerLifecycleObservers()
  }

  deinit {
    for observer in lifecycleObservers {
      notificationCenter.removeObserver(observer)
    }
  }

  func status(for type: PermissionType) -> PermissionStatus {
    if let status = statuses[type] {
      return status
    }
    let status = computeStatus(for: type)
    statuses[type] = status
    return status
  }

  func refreshAll() {
    PermissionType.allCases.forEach { type in
      refresh(type)
    }
  }

  func refresh(_ type: PermissionType) {
    let status = computeStatus(for: type)
    statuses[type] = status
    if status != .notDetermined {
      requestIssues[type] = nil
    }
  }

  func requestIssue(for type: PermissionType) -> PermissionRequestIssue? {
    requestIssues[type]
  }

  func request(_ type: PermissionType) async -> PermissionStatus {
    requestIssues[type] = nil
    let status: PermissionStatus
    switch type {
    case .microphone:
      status = await requestMicrophone()
    case .speechRecognition:
      status = await requestSpeechRecognition()
    case .accessibility:
      status = requestAccessibility()
    case .inputMonitoring:
      status = requestInputMonitoring()
    }

    statuses[type] = status
    return status
  }

  func ensureGranted(_ type: PermissionType) async -> PermissionStatus {
    refresh(type)
    let current = status(for: type)
    guard !current.isGranted else { return current }
    guard current == .notDetermined else { return current }
    return await request(type)
  }

  nonisolated func ensureKeychainAccess(forService service: String) async -> Bool {
    // Attempt a scoped, non-destructive lookup within our service namespace. This avoids prompting
    // for unrelated keychain items while still surfacing permission failures.
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnData as String: false,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    let status = SecItemCopyMatching(query as CFDictionary, nil)
    switch status {
    case errSecSuccess, errSecItemNotFound:
      return true
    case errSecInteractionNotAllowed, errSecMissingEntitlement:
      return false
    default:
      return true
    }
  }

  private func computeStatus(for type: PermissionType) -> PermissionStatus {
    statusProvider(type)
  }

  private nonisolated static func systemStatus(for type: PermissionType) -> PermissionStatus {
    switch type {
    case .microphone:
      return microphoneStatus()
    case .speechRecognition:
      return speechRecognitionStatus()
    case .accessibility:
      return AXIsProcessTrusted() ? .granted : .denied
    case .inputMonitoring:
      return inputMonitoringStatus(
        hasListenAccess: CGPreflightListenEventAccess(),
        hasAccessibilityAccess: AXIsProcessTrusted()
      )
    }
  }

  private nonisolated static func microphoneStatus() -> PermissionStatus {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return .granted
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .restricted: return .restricted
    @unknown default: return .restricted
    }
  }

  private nonisolated static func speechRecognitionStatus() -> PermissionStatus {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: return .granted
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .restricted: return .restricted
    @unknown default: return .restricted
    }
  }

  /// Accessibility permission is a superset of event-listening permission on macOS.
  /// Treat either TCC grant as effective access so the app does not report Input
  /// Monitoring as disabled while its global event tap is allowed to run.
  nonisolated static func inputMonitoringStatus(
    hasListenAccess: Bool,
    hasAccessibilityAccess: Bool
  ) -> PermissionStatus {
    hasListenAccess || hasAccessibilityAccess ? .granted : .denied
  }

  nonisolated static func shouldPromptForAccessibility(channel: DistributionChannel) -> Bool {
    channel.supportsAutomaticAccessibilityPrompt
  }

  private func requestMicrophone() async -> PermissionStatus {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    return granted ? .granted : .denied
  }

  private func requestSpeechRecognition() async -> PermissionStatus {
    let gate = SpeechAuthorizationRequestGate()
    let requester = speechAuthorizationRequester
    let timeout = speechAuthorizationTimeout
    let outcome = await withCheckedContinuation { continuation in
      gate.install(continuation)
      requester { status in
        gate.resolve(.status(Self.mapSpeechAuthorizationStatus(status)))
      }
      Task {
        try? await Task.sleep(for: .seconds(timeout))
        gate.resolve(.timedOut)
      }
    }

    switch outcome {
    case .status(let status):
      return status
    case .timedOut:
      requestIssues[.speechRecognition] = .timedOut
      return computeStatus(for: .speechRecognition)
    }
  }

  private nonisolated static func mapSpeechAuthorizationStatus(
    _ status: SFSpeechRecognizerAuthorizationStatus
  ) -> PermissionStatus {
    switch status {
    case .authorized:
      return .granted
    case .notDetermined:
      return .notDetermined
    case .denied:
      return .denied
    case .restricted:
      return .restricted
    @unknown default:
      return .restricted
    }
  }

  private func requestAccessibility() -> PermissionStatus {
    let trusted: Bool
    if Self.shouldPromptForAccessibility(channel: DistributionChannel.current) {
      let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
      trusted = AXIsProcessTrustedWithOptions(options)
    } else {
      // The App Store sandbox cannot present the Accessibility prompt. It can
      // only observe a grant the user made manually in System Settings.
      trusted = AXIsProcessTrusted()
    }
    return trusted ? .granted : .denied
  }

  private func requestInputMonitoring() -> PermissionStatus {
    let granted = CGRequestListenEventAccess()
    return Self.inputMonitoringStatus(
      hasListenAccess: granted,
      hasAccessibilityAccess: AXIsProcessTrusted()
    )
  }

  private func registerLifecycleObservers() {
    lifecycleObservers = [
      notificationCenter.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.refreshAll()
        }
      }
    ]
  }
}
