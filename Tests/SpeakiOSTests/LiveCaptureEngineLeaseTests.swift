#if os(iOS)
import AVFoundation
import XCTest
@testable import SpeakiOSLib

@MainActor
final class LiveCaptureEngineLeaseTests: XCTestCase {
    private var returns = 0
    private let lentEngine = AVAudioEngine()

    override func tearDown() {
        LiveCaptureInput.engineLender = nil
        super.tearDown()
    }

    private func makeInput() -> LiveCaptureInput {
        let manager = AudioSessionManager()
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        return LiveCaptureInput(audioSessionManager: manager)
    }

    private func lendEngine() {
        LiveCaptureInput.engineLender = { [unowned self] in
            LiveCaptureInput.EngineLease(engine: lentEngine) { [unowned self] in returns += 1 }
        }
    }

    func testClaim_recordsOnLentReadinessEngineAndHaltGivesItBackOnce() async throws {
        lendEngine()
        let input = makeInput()
        try await input.claimAudioSession()
        XCTAssertTrue(input.isUsingLentEngine)
        XCTAssertTrue(input.engine === lentEngine)

        input.halt()
        input.releaseAudioSession()

        XCTAssertEqual(returns, 1)
        XCTAssertFalse(input.isUsingLentEngine)
        XCTAssertFalse(input.engine === lentEngine)
    }

    func testRelease_withoutHaltStillGivesLentEngineBack() async throws {
        lendEngine()
        let input = makeInput()
        try await input.claimAudioSession()
        input.releaseAudioSession()
        XCTAssertEqual(returns, 1)
    }

    func testClaim_withoutLenderUsesOwnEngine() async throws {
        let input = makeInput()
        try await input.claimAudioSession()
        XCTAssertFalse(input.isUsingLentEngine)
        XCTAssertFalse(input.engine === lentEngine)
        input.releaseAudioSession()
        XCTAssertEqual(returns, 0)
    }
}
#endif
