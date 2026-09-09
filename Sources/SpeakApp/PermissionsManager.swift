import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import SpeakCore
import Speech

// @Implement This class manages system permissions. It knows how to request the following permissions when asked and also surface the current status of permissions as per the system

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
  private lazy var settingsGuide = PermissionSettingsGuide()
  private let guidePresenter: ((PermissionType) -> Void)?

  init(
    statusProvider: @escaping (PermissionType) -> PermissionStatus = PermissionsManager.systemStatus,
    speechAuthorizationRequester: @escaping SpeechAuthorizationRequester = { callback in
      SFSpeechRecognizer.requestAuthorization(callback)
    },
    speechAuthorizationTimeout: TimeInterval = 8,
    notificationCenter: NotificationCenter = .default,
    guidePresenter: ((PermissionType) -> Void)? = nil
  ) {
    self.statusProvider = statusProvider
    self.speechAuthorizationRequester = speechAuthorizationRequester
    self.speechAuthorizationTimeout = speechAuthorizationTimeout
    self.notificationCenter = notificationCenter
    self.guidePresenter = guidePresenter
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

  /// Explicit user actions get Settings guidance; background permission checks never open windows.
  func requestWithGuidance(_ type: PermissionType) async -> PermissionStatus {
    refresh(type)
    let current = status(for: type)
    guard !current.isGranted else { return current }
    guard PermissionType.availablePermissions(for: DistributionChannel.current).contains(type) else {
      return current
    }
    // Accessibility can be added by dragging the app. Avoid a second macOS alert
    // covering the guide. Denied/restricted prompt-based permissions cannot re-prompt.
    if type == .accessibility || current == .restricted
      || (current == .denied && type != .inputMonitoring) {
      openSettings(for: type)
      return current
    }
    let result = await request(type)
    if !result.isGranted { openSettings(for: type) }
    return result
  }

  func openSettings(for type: PermissionType) {
    guard PermissionType.availablePermissions(for: DistributionChannel.current).contains(type) else { return }
    if let guidePresenter {
      guidePresenter(type)
    } else {
      settingsGuide.show(type, permissions: self)
    }
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
