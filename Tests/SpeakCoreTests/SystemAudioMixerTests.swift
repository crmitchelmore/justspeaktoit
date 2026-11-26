import Foundation
import SpeakCore
import XCTest

final class SystemAudioMixerTests: XCTestCase {
    func testSystemMode_passesSystemSamplesThroughAndIgnoresMic() {
        let mixer = SystemAudioMixer(source: .system, sampleRate: 1_000)
        XCTAssertEqual(mixer.pushSystem([0.25, -0.5]), [0.25, -0.5])
        XCTAssertEqual(mixer.pushMicrophone([0.5, 0.5]), [])
        XCTAssertEqual(mixer.flush(), [])
    }

    func testBothMode_mixesOverlappingSamplesWithClamping() {
        let mixer = SystemAudioMixer(source: .both, sampleRate: 1_000, maxLagMilliseconds: 100)
        XCTAssertEqual(mixer.pushSystem([0.6, -0.8, 0.25]), [])
        let mixed = mixer.pushMicrophone([0.7, -0.5, 0.25])
        XCTAssertEqual(mixed.count, 3)
        XCTAssertEqual(mixed[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(mixed[1], -1.0, accuracy: 0.0001)
        XCTAssertEqual(mixed[2], 0.5, accuracy: 0.0001)
    }

    func testBothMode_drainsExcessWhenOneStreamIsSilent() {
        let mixer = SystemAudioMixer(source: .both, sampleRate: 1_000, maxLagMilliseconds: 4)
        // 4ms at 1000 Hz = 4 samples lag budget; pushing 6 drains 2 immediately.
        let drained = mixer.pushSystem([0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
        XCTAssertEqual(drained, [0.1, 0.2])
        // Flush emits the remaining 4 buffered samples.
        XCTAssertEqual(mixer.flush(), [0.3, 0.4, 0.5, 0.6])
    }

    func testReset_clearsBufferedSamples() {
        let mixer = SystemAudioMixer(source: .both, sampleRate: 1_000, maxLagMilliseconds: 100)
        _ = mixer.pushSystem([0.1, 0.2, 0.3])
        mixer.reset()
        XCTAssertEqual(mixer.flush(), [])
    }

    // MARK: - Automation protocol & dispatch

    func testAutomationRequest_validatesAudioCaptureSource() throws {
        var valid = AutomationRequest(command: .startDictation)
        valid.source = "system"
        XCTAssertEqual(try valid.validated().source, "system")

        var invalidSource = AutomationRequest(command: .startDictation)
        invalidSource.source = "speakers"
        XCTAssertThrowsError(try invalidSource.validated()) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .invalidArgument)
        }

        var wrongCommand = AutomationRequest(command: .status)
        wrongCommand.source = "system"
        XCTAssertThrowsError(try wrongCommand.validated()) { error in
            XCTAssertEqual((error as? AutomationError)?.code, .invalidArgument)
        }
    }

    func testDispatcher_routesSourceToCaptureSourceHost() async {
        final class SourceHost: AutomationCaptureSourceHost, @unchecked Sendable {
            var startedSource: AudioCaptureSource?
            func automationStatus() async -> AutomationResult { AutomationResult(sessionActive: false) }
            func automationHistory(limit: Int) async -> [AutomationHistoryEntry] { [] }
            func automationTranscribeFile(at url: URL) async throws -> AutomationResult { AutomationResult() }
            func automationStartDictation() async throws -> AutomationResult {
                try await self.automationStartDictation(source: .mic)
            }
            func automationStartDictation(source: AudioCaptureSource) async throws -> AutomationResult {
                self.startedSource = source
                var result = AutomationResult(sessionActive: true)
                result.source = source.rawValue
                return result
            }
            func automationStopDictation() async throws -> AutomationResult { AutomationResult(sessionActive: false) }
        }

        let host = SourceHost()
        var request = AutomationRequest(command: .startDictation)
        request.source = "both"
        let response = await AutomationCommandDispatcher.response(to: request, host: host)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(host.startedSource, .both)
        XCTAssertEqual(response.result?.source, "both")
    }

    func testDispatcher_rejectsSystemAudioOnHostWithoutCaptureSourceSupport() async {
        final class BasicHost: AutomationCommandHost, @unchecked Sendable {
            func automationStatus() async -> AutomationResult { AutomationResult(sessionActive: false) }
            func automationHistory(limit: Int) async -> [AutomationHistoryEntry] { [] }
            func automationTranscribeFile(at url: URL) async throws -> AutomationResult { AutomationResult() }
            func automationStartDictation() async throws -> AutomationResult { AutomationResult(sessionActive: true) }
            func automationStopDictation() async throws -> AutomationResult { AutomationResult(sessionActive: false) }
        }

        let host = BasicHost()
        var systemReq = AutomationRequest(command: .startDictation)
        systemReq.source = "system"
        let systemResp = await AutomationCommandDispatcher.response(to: systemReq, host: host)
        XCTAssertFalse(systemResp.ok)
        XCTAssertEqual(systemResp.error?.code, .unsupportedCommand)

        var micReq = AutomationRequest(command: .startDictation)
        micReq.source = "mic"
        let micResp = await AutomationCommandDispatcher.response(to: micReq, host: host)
        XCTAssertTrue(micResp.ok)
    }
}
