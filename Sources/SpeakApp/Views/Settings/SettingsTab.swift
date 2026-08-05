import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
  case general
  case transcription
  case postProcessing
  case voiceOutput
  case pronunciation
  case apiKeys
  case shortcuts
  case permissions
  case about

  var id: String { rawValue }

  var title: String {
    title(isAssemblyAI: false)
  }

  func title(isAssemblyAI: Bool) -> String {
    switch self {
    case .general: return "General"
    case .transcription: return "Transcription"
    case .postProcessing: return isAssemblyAI ? "Pre-processing" : "Post-processing"
    case .voiceOutput: return "Voice Output"
    case .pronunciation: return "Pronunciation"
    case .apiKeys: return "API Keys"
    case .shortcuts: return "Keyboard"
    case .permissions: return "Permissions"
    case .about: return "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: return "gearshape"
    case .transcription: return "waveform"
    case .postProcessing: return "wand.and.stars"
    case .voiceOutput: return "speaker.wave.3"
    case .pronunciation: return "character.book.closed"
    case .apiKeys: return "key.fill"
    case .shortcuts: return "keyboard"
    case .permissions: return "hand.raised.fill"
    case .about: return "info.circle"
    }
  }
}
