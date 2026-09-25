import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopCaptureFramingTests: XCTestCase {
    func testDeepgramAvoidsOneHundredMillisecondApplicationBatches() {
        let models = DesktopLiveTranscription.liveModels.filter {
            DesktopLiveTranscription.route(forID: $0.id)?.provider == .deepgram
        }
        XCTAssertFalse(models.isEmpty)
        for model in models {
            XCTAssertEqual(DesktopLiveTranscription.captureFrameMilliseconds(forID: model.id), 20, model.id)
            XCTAssertEqual(DesktopLiveTranscription.captureFrameMilliseconds(forID: " \(model.id) \n"), 20)
        }
    }

    func testOtherImplementedRoutesRetainExistingFramingIncludingAssemblyAIMinimum() {
        for model in DesktopLiveTranscription.liveModels {
            guard let route = DesktopLiveTranscription.route(forID: model.id), route.provider != .deepgram else {
                continue
            }
            let milliseconds = DesktopLiveTranscription.captureFrameMilliseconds(forID: model.id)
            XCTAssertEqual(milliseconds, 100, model.id)
            if route.provider == .assemblyai {
                XCTAssertTrue((50...1000).contains(milliseconds), "AssemblyAI rejects sub-50 ms audio messages")
            }
            XCTAssertEqual(route.sampleRate * milliseconds % 1000, 0, "Frames contain whole PCM samples")
        }
    }

    func testBatchAndUnavailableModelsKeepLegacyDefault() {
        for identifier in ["deepgram/nova-3", "deepgram/unknown-streaming", "future/live", ""] {
            XCTAssertEqual(DesktopLiveTranscription.captureFrameMilliseconds(forID: identifier), 100, identifier)
        }
    }
}
