import Foundation
import SpeakCore

/// State for the pre-flight "API key required" alert shown when the user
/// triggers a live recording but the chosen live transcription provider has
/// no API key stored. The alert exposes an "Add API Key" CTA which navigates
/// to Settings → API Keys, scrolled to the relevant provider section.
struct MissingLiveAPIKeyAlert: Identifiable, Equatable {
  let id = UUID()
  let provider: TranscriptionProviderMetadata
  let modelDisplayName: String

  var title: String { "API key required" }

  var message: String {
    "\(provider.displayName) needs an API key for live transcription "
      + "with \(modelDisplayName). Add it now and try again."
  }

  static func == (lhs: MissingLiveAPIKeyAlert, rhs: MissingLiveAPIKeyAlert) -> Bool {
    lhs.id == rhs.id
  }
}
