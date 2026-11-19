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
    let base = "\(provider.displayName) needs an API key for transcription "
      + "with \(modelDisplayName). Add it now and try again."
    guard let summary = APIKeyGuidance.promptSummary(for: provider.apiKeyIdentifier, uses: .transcription) else {
      return base
    }
    return base + " " + summary
  }

  /// The provider's key-creation page from the shared guide, else its website.
  var keyPageURL: URL? {
    APIKeyCatalog.keyPageURL(for: provider.apiKeyIdentifier) ?? provider.apiKeyURL
  }

  static func == (lhs: MissingLiveAPIKeyAlert, rhs: MissingLiveAPIKeyAlert) -> Bool {
    lhs.id == rhs.id
  }
}
