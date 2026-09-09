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
    switch self {
    case .microphone:
      return "Allow Speak to access your microphone so we can capture your words the moment you press record."
    case .speechRecognition:
      return "Grant macOS speech recognition so Speak can turn your recordings into on-screen text in real time."
    case .accessibility:
      return "Enable Accessibility so Speak can insert transcribed text into other apps."
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
        "Drag the app from the guide into the list, or click + to select it.",
        "Enable the app’s switch and unlock with your password or Touch ID if asked.",
        "Quit and reopen the app only if macOS asks you to."
      ]
    case .microphone, .speechRecognition:
      return nil
    }
  }
}
