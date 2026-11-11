import SpeakCore
import XCTest

final class LiveStopGracePolicyTests: XCTestCase {
    func testHostWaitedProviders_keepTheirHistoricGraceAndClientTimedProvidersWaitNothing() {
        for provider in [LiveTranscriptionProviderID.deepgram, .soniox, .modulate, .openai] {
            XCTAssertEqual(LiveStopGracePolicy.hostDelay(for: provider, grace: 3), 3, provider.rawValue)
        }
        XCTAssertEqual(LiveStopGracePolicy.hostDelay(for: .elevenlabs, grace: 3), 2)
        XCTAssertEqual(LiveStopGracePolicy.hostDelay(for: .elevenlabs, grace: 0.5), 0.5)
        for provider in [LiveTranscriptionProviderID.cartesia, .assemblyai, .gladia, .xai, .apple] {
            XCTAssertEqual(LiveStopGracePolicy.hostDelay(for: provider, grace: 3), 0, provider.rawValue)
        }
    }

    func testInvalidGrace_isNeverWaited() {
        for grace in [-1, 0, .infinity, .nan] as [TimeInterval] {
            XCTAssertEqual(LiveStopGracePolicy.hostDelay(for: .deepgram, grace: grace), 0)
        }
    }

    func testCompletionTimeout_outlivesBudgetAndDelayButNeverDropsBelowTenSeconds() {
        XCTAssertEqual(LiveStopGracePolicy.completionTimeout(finalisationBudget: nil, hostDelay: 0), 10)
        XCTAssertEqual(LiveStopGracePolicy.completionTimeout(finalisationBudget: nil, hostDelay: 2), 12)
        XCTAssertEqual(LiveStopGracePolicy.completionTimeout(finalisationBudget: 3, hostDelay: 0), 10)
        XCTAssertEqual(LiveStopGracePolicy.completionTimeout(finalisationBudget: 10, hostDelay: 2), 13)
        XCTAssertEqual(LiveStopGracePolicy.completionTimeout(finalisationBudget: .infinity, hostDelay: 0), 10)
    }
}
