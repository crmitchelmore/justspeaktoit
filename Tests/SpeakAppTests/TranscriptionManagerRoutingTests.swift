import XCTest

@testable import SpeakApp

final class TranscriptionManagerRoutingTests: XCTestCase {
  func testResolvedLiveTranscriptionModel_usesLiveModelOutsideLocalStreaming() throws {
    let model = try TranscriptionManager.resolvedLiveTranscriptionModel(
      transcriptionMode: .liveNative,
      localTranscriptionMode: .streaming,
      localStreamingModelSource: "",
      liveTranscriptionModel: "deepgram/nova-3-streaming",
      availableStreamingSourceIDs: []
    )

    XCTAssertEqual(model, "deepgram/nova-3-streaming")
  }

  func testResolvedLiveTranscriptionModel_returnsValidLocalStreamingSource() throws {
    let sourceID = "local/streaming/example"
    let model = try TranscriptionManager.resolvedLiveTranscriptionModel(
      transcriptionMode: .localModel,
      localTranscriptionMode: .streaming,
      localStreamingModelSource: sourceID,
      liveTranscriptionModel: "apple/local/SFSpeechRecognizer",
      availableStreamingSourceIDs: [sourceID]
    )

    XCTAssertEqual(model, sourceID)
  }

  #if !APP_STORE
  func testResolvedLiveTranscriptionModel_returnsFluidAudioParakeetSource() throws {
    let model = try TranscriptionManager.resolvedLiveTranscriptionModel(
      transcriptionMode: .localModel,
      localTranscriptionMode: .streaming,
      localStreamingModelSource: FluidAudioParakeetModel.id,
      liveTranscriptionModel: "apple/local/SFSpeechRecognizer",
      availableStreamingSourceIDs: [FluidAudioParakeetModel.id]
    )

    XCTAssertEqual(model, FluidAudioParakeetModel.id)
  }
  #endif

  func testResolvedLiveTranscriptionModel_rejectsInvalidLocalStreamingSource() {
    XCTAssertThrowsError(
      try TranscriptionManager.resolvedLiveTranscriptionModel(
        transcriptionMode: .localModel,
        localTranscriptionMode: .streaming,
        localStreamingModelSource: "",
        liveTranscriptionModel: "apple/local/SFSpeechRecognizer",
        availableStreamingSourceIDs: []
      )
    ) { error in
      XCTAssertEqual(
        error as? TranscriptionManagerError,
        .invalidLocalStreamingSource("")
      )
    }
  }
}
