import Foundation
import SpeakCore

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
    let appName = RunningAppIdentity.current.name
    switch self {
    case .microphone:
      return "Allow \(appName) to use your microphone when you record."
    case .speechRecognition:
      return "Allow \(appName) to transcribe recordings with Apple Speech."
    case .accessibility:
      return "Enable Accessibility so \(appName) can insert transcribed text into other apps."
    case .inputMonitoring:
      return "Permit hotkey monitoring so \(appName) notices only the shortcuts you assign—nothing more."
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
        "Drag \(RunningAppIdentity.current.name) from the guide into the list, or use Show App to locate it.",
        "Enable the app’s switch and unlock with your password or Touch ID if asked.",
        RunningAppIdentity.current.recoveryInstructions
      ]
    case .microphone, .speechRecognition:
      return nil
    }
  }
}
