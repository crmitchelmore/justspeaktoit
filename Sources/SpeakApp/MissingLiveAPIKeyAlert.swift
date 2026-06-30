import Foundation
import SpeakCore

/// State for the "API key required" alert shown when the user selects or starts
/// a transcription model whose provider has no API key stored.
struct MissingLiveAPIKeyAlert: Identifiable, Equatable {
  let id = UUID()
  let provider: TranscriptionProviderMetadata
  let modelDisplayName: String

  var title: String { "API key required" }

  var message: String {
    "\(provider.displayName) needs an API key for transcription "
      + "with \(modelDisplayName). Add it now and try again."
  }

  static func == (lhs: MissingLiveAPIKeyAlert, rhs: MissingLiveAPIKeyAlert) -> Bool {
    lhs.id == rhs.id
  }
}

extension TranscriptionProviderMetadata {
  var apiKeyURL: URL? {
    guard !website.isEmpty else { return nil }
    return URL(string: website)
  }
}
