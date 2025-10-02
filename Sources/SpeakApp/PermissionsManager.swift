import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import Speech

// @Implement This class manages system permissions. It knows how to request the following permissions when asked and also surface the current status of permissions as per the system

enum PermissionType: CaseIterable, Identifiable {
  case microphone
  case speechRecognition
  case accessibility
  case inputMonitoring

  var id: String { displayName }

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

@MainActor
final class PermissionsManager: ObservableObject {
  @Published private(set) var statuses: [PermissionType: PermissionStatus] = [:]

  init() {
    refreshAll()
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
      statuses[type] = computeStatus(for: type)
    }
  }

  func request(_ type: PermissionType) async -> PermissionStatus {
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

  func ensureKeychainAccess(forService service: String) async -> Bool {
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
    switch type {
    case .microphone:
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
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
    case .speechRecognition:
      switch SFSpeechRecognizer.authorizationStatus() {
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
    case .accessibility:
      return AXIsProcessTrusted() ? .granted : .denied
    case .inputMonitoring:
      let granted = CGPreflightListenEventAccess()
      return granted ? .granted : .denied
    }
  }

  private func requestMicrophone() async -> PermissionStatus {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    return granted ? .granted : .denied
  }

  private func requestSpeechRecognition() async -> PermissionStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        let mapped: PermissionStatus
        switch status {
        case .authorized:
          mapped = .granted
        case .notDetermined:
          mapped = .notDetermined
        case .denied:
          mapped = .denied
        case .restricted:
          mapped = .restricted
        @unknown default:
          mapped = .restricted
        }
        continuation.resume(returning: mapped)
      }
    }
  }

  private func requestAccessibility() -> PermissionStatus {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
    let trusted = AXIsProcessTrustedWithOptions(options)
    return trusted ? .granted : .denied
  }

  private func requestInputMonitoring() -> PermissionStatus {
    let granted = CGRequestListenEventAccess()
    return granted ? .granted : .denied
  }
}
