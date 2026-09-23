import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import XCTest

/// Live acceptance of the production Ink-2 request against Cartesia's service.
/// Never part of an ordinary run: it skips unless explicitly enabled with a
/// standard API key (`sk_car_…`; admin keys are rejected for speech-to-text) in
/// the environment, which it never prints. It opens the exact handshake every
/// client of the stream opens (bearer key, pinned `Cartesia-Version`), sends
/// one second of generated silence as ten 100 ms frames, finishes, and needs
/// the documented end: the service's normal closure (1000) after `close`, with
/// no error. Silence has no words, so no transcript is expected.
///
///     JSTI_CARTESIA_SERVICE_PROBE=1 CARTESIA_API_KEY=<standard key> \
///       SPEAK_PORTABLE_CORE=1 xcrun swift test --filter CartesiaServiceAcceptanceTests
final class CartesiaServiceAcceptanceTests: XCTestCase {
    func testProductionRequestEndsOnTheServicesNormalClosure() async throws {
        #if canImport(FoundationNetworking)
        throw XCTSkip("FoundationNetworking is not a qualified WebSocket transport; Windows uses WinHTTP.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["JSTI_CARTESIA_SERVICE_PROBE"] == "1", let key = environment["CARTESIA_API_KEY"],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set JSTI_CARTESIA_SERVICE_PROBE=1 and CARTESIA_API_KEY to probe Cartesia's service.")
        }
        let outcome = CartesiaServiceOutcome()
        let client = CartesiaLiveClient(apiKey: key)
        client.start(onTranscript: { text, isFinal in outcome.transcript(text, isFinal: isFinal) },
                     onError: { outcome.fail($0) })
        for _ in 0..<10 { client.sendAudio(Data(count: 3_200)) }
        let began = Date()
        let transcript = await client.finishAndWait()
        let elapsed = Date().timeIntervalSince(began)
        client.cancel()
        let report = "errors: \(outcome.errors), finals: \(outcome.finals), "
            + "transcript: \(transcript ?? "none"), finish: \(String(format: "%.2f", elapsed)) s"
        XCTAssertTrue(outcome.errors.isEmpty, report)
        XCTAssertLessThan(elapsed, CartesiaLiveClient.finishBudget, "The closure, not the deadline, ends it: \(report)")
        #endif
    }
}

/// What the service did, in forms that cannot carry the key: typed errors
/// print their case (for example `closed(code: 1001)`), never a header.
private final class CartesiaServiceOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []
    private var finalTexts: [String] = []

    var errors: [String] { lock.withLock { failures } }
    var finals: [String] { lock.withLock { finalTexts } }

    func transcript(_ text: String, isFinal: Bool) {
        guard isFinal else { return }
        lock.withLock { finalTexts.append(text) }
    }

    func fail(_ error: Error) {
        lock.withLock { failures.append(String(describing: error)) }
    }
}
