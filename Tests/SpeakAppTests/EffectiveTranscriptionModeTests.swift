import XCTest

@testable import SpeakApp

final class EffectiveTranscriptionModeTests: XCTestCase {
  func testAppleSpeech_isIdentifiedAsOnDevice() {
    let label = AppSettings.effectiveTranscriptionModeDisplayName(
      transcriptionMode: .liveNative,
      liveTranscriptionModel: "apple/local/SFSpeechRecognizer",
      localTranscriptionMode: .batch
    )

    XCTAssertEqual(label, "Apple On-Device")
  }

  func testRemoteLiveModel_isIdentifiedAsRemoteStreaming() {
    let label = AppSettings.effectiveTranscriptionModeDisplayName(
      transcriptionMode: .liveNative,
      liveTranscriptionModel: "deepgram/nova-3-streaming",
      localTranscriptionMode: .batch
    )

    XCTAssertEqual(label, "Remote Streaming")
  }

  func testRemoteBatch_keepsItsModeLabel() {
    let label = AppSettings.effectiveTranscriptionModeDisplayName(
      transcriptionMode: .batchRemote,
      liveTranscriptionModel: "apple/local/SFSpeechRecognizer",
      localTranscriptionMode: .streaming
    )

    XCTAssertEqual(label, "Remote Batch")
  }

  func testDownloadedLocalModels_useTheirConfiguredMode() {
    let batchLabel = AppSettings.effectiveTranscriptionModeDisplayName(
      transcriptionMode: .localModel,
      liveTranscriptionModel: "deepgram/nova-3-streaming",
      localTranscriptionMode: .batch
    )
    let streamingLabel = AppSettings.effectiveTranscriptionModeDisplayName(
      transcriptionMode: .localModel,
      liveTranscriptionModel: "deepgram/nova-3-streaming",
      localTranscriptionMode: .streaming
    )

    XCTAssertEqual(batchLabel, "Local Batch")
    XCTAssertEqual(streamingLabel, "Local Streaming")
  }
}
