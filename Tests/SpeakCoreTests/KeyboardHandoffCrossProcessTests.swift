import Foundation
import XCTest

@testable import SpeakCore

/// Cross-process atomicity for the keyboard handoff (issue #712): the app and
/// the extension are modelled as two independent store instances with their
/// own locks over one shared defaults suite — exactly the production shape a
/// single in-process `NSLock` cannot protect. Control commands must always
/// beat interim/text writes, phases must be monotonic, old processes must not
/// mutate replacement requests, and expiry normalisation must never write.
final class KeyboardHandoffCrossProcessTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// The containing app's store instance.
    private var app: KeyboardHandoffStore!
    /// The keyboard extension's store instance (independent lock).
    private var ext: KeyboardHandoffStore!

    override func setUp() {
        super.setUp()
        suiteName = "keyboard-handoff-xproc-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        app = KeyboardHandoffStore(defaults: defaults, role: .containingApp)
        ext = KeyboardHandoffStore(defaults: defaults, role: .keyboardExtension)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        app = nil
        ext = nil
        super.tearDown()
    }

    private func startRecordingRequest() throws -> UUID {
        let request = try ext.createRequest()
        _ = try app.markRecording(requestID: request.requestID)
        return request.requestID
    }

    // MARK: - The reported race

    func testExtensionCancel_alwaysBeatsInterleavedAppInterimWrites() throws {
        let requestID = try startRecordingRequest()
        _ = try app.updateInterim(requestID: requestID, transcript: "hello wor")

        // The user cancels from the keyboard while the app is mid-stream.
        _ = try ext.cancel(requestID: requestID)

        // The app's next interim write — the exact stale whole-record pattern
        // that used to resurrect `.recording` — must be refused, and every
        // reader must see the cancellation.
        XCTAssertThrowsError(
            try app.updateInterim(requestID: requestID, transcript: "hello world")
        ) { error in
            XCTAssertEqual(error as? KeyboardHandoffStoreError, .invalidTransition)
        }
        XCTAssertEqual(app.activeRecord()?.phase, .cancelled)
        XCTAssertEqual(ext.activeRecord()?.phase, .cancelled)
    }

    func testExtensionFinish_isNotRegressedByInterimWrites() throws {
        let requestID = try startRecordingRequest()
        _ = try ext.requestFinish(requestID: requestID)
        XCTAssertEqual(app.activeRecord()?.phase, .finishRequested)

        XCTAssertThrowsError(
            try app.updateInterim(requestID: requestID, transcript: "late text")
        )
        XCTAssertEqual(app.activeRecord()?.phase, .finishRequested)

        // The app honours the finish by moving forward, never back.
        _ = try app.markTranscribing(requestID: requestID)
        XCTAssertEqual(ext.activeRecord()?.phase, .transcribing)
    }

    // MARK: - Monotonicity

    func testCommandChannel_cancelOutranksFinishAndNeverDowngrades() throws {
        let requestID = try startRecordingRequest()
        _ = try ext.requestFinish(requestID: requestID)
        // Cancel escalates over finish…
        _ = try ext.cancel(requestID: requestID)
        XCTAssertEqual(app.activeRecord()?.phase, .cancelled)

        // …and a late finish can never downgrade the cancel.
        XCTAssertThrowsError(try ext.requestFinish(requestID: requestID))
        XCTAssertEqual(app.activeRecord()?.phase, .cancelled)
    }

    func testTerminalPhases_absorbLateAppWrites() throws {
        let requestID = try startRecordingRequest()
        _ = try ext.cancel(requestID: requestID)

        XCTAssertThrowsError(try app.markTranscribing(requestID: requestID))
        XCTAssertThrowsError(try app.complete(requestID: requestID, transcript: "text"))
        XCTAssertThrowsError(try app.fail(requestID: requestID, code: .noSpeech))
        XCTAssertEqual(app.activeRecord()?.phase, .cancelled)
    }

    func testAppSideCancel_stopsTheRequestThroughItsOwnChannel() throws {
        let requestID = try startRecordingRequest()
        _ = try app.cancel(requestID: requestID)
        XCTAssertEqual(ext.activeRecord()?.phase, .cancelled)
    }

    // MARK: - Old-process isolation

    func testSuspendedOldExtension_cannotMutateAReplacementRequest() throws {
        let oldRequest = try startRecordingRequest()

        // The old extension process is suspended; a new keyboard session
        // replaces the request.
        ext.clear(requestID: oldRequest)
        let replacement = try ext.createRequest()

        // The old process resumes and issues its stale writes.
        let staleExtension = KeyboardHandoffStore(defaults: defaults, role: .keyboardExtension)
        XCTAssertThrowsError(try staleExtension.cancel(requestID: oldRequest)) { error in
            XCTAssertEqual(error as? KeyboardHandoffStoreError, .mismatchedRequest)
        }
        let staleApp = KeyboardHandoffStore(defaults: defaults, role: .containingApp)
        XCTAssertThrowsError(
            try staleApp.updateInterim(requestID: oldRequest, transcript: "ghost")
        )

        XCTAssertEqual(app.activeRecord()?.requestID, replacement.requestID)
        XCTAssertEqual(app.activeRecord()?.phase, .requested)
        XCTAssertNil(app.activeRecord()?.interimTranscript)
    }

    // MARK: - Expiry

    func testExpiryNormalisation_neverWritesOnRead() throws {
        let request = try ext.createRequest(lifetime: 0.01)
        Thread.sleep(forTimeInterval: 0.05)

        let intentBefore = defaults.data(forKey: "keyboardHandoff.intent.v4")
        let statusBefore = defaults.data(forKey: "keyboardHandoff.status.v4")

        // Both processes read the expired record concurrently-ish; the view is
        // timed out, but nothing may be written back.
        XCTAssertEqual(app.activeRecord()?.phase, .failed)
        XCTAssertEqual(app.activeRecord()?.failureCode, .timedOut)
        XCTAssertEqual(ext.record(matching: request.requestID)?.failureCode, .timedOut)

        XCTAssertEqual(defaults.data(forKey: "keyboardHandoff.intent.v4"), intentBefore)
        XCTAssertEqual(defaults.data(forKey: "keyboardHandoff.status.v4"), statusBefore)
    }

    // MARK: - Result handoff still works end to end

    func testHappyPath_finishTranscribeCompleteConsume() throws {
        let requestID = try startRecordingRequest()
        _ = try app.updateInterim(requestID: requestID, transcript: "hello")
        _ = try ext.requestFinish(requestID: requestID)
        _ = try app.markTranscribing(requestID: requestID)
        _ = try app.complete(requestID: requestID, transcript: "hello world")

        XCTAssertEqual(ext.consumeResult(requestID: requestID), "hello world")
        XCTAssertNil(ext.activeRecord())
        XCTAssertNil(app.activeRecord())
    }
}
