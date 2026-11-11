import Foundation
import SpeakCore

struct AssemblyAITranscriptionProvider: SharedBatchClientProvider {
  let batchClient: AssemblyAIBatchClient

  init(session: URLSession = .shared) {
    batchClient = AssemblyAIBatchClient(session: session, durationResolver: AppleAudioDuration.asset)
  }

  func mapSpeechModels(from model: String) -> [String] { batchClient.mapSpeechModels(from: model) }
}
