import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostObservationalLearningTests: XCTestCase {
    func testNoConsentAndGenericAllow_CannotReadObservationalSpan() async throws {
        let fixture = try ObservationalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.host.observationalOutputAndWait()
        XCTAssertEqual(fixture.span.begins, 0)
        do {
            _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowLearning")
            XCTFail("Generic acknowledged-learning approval must not authorize AT-SPI observation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Observational"))
        }
        await fixture.host.observationalOutputAndWait()
        XCTAssertEqual(fixture.span.begins, 0)
        await fixture.host.close()
    }

    func testImportEnabledAndConsentMirrors_CannotGrantSessionConsent() async throws {
        let fixture = try ObservationalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.autoCorrectionsEnabled.rawValue: AnyCodable(.bool(true)),
            "observationalCorrectionConsent": AnyCodable(.bool(true)),
            "correctionLearningApproved": AnyCodable(.bool(true))
        ])
        let url = fixture.root.appendingPathComponent("import.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: configuration)).write(to: url)
        try await fixture.host.importConfiguration(path: url.path)
        await fixture.host.observationalOutputAndWait()
        let consent = await fixture.host.observationalConsentForTest()
        XCTAssertFalse(consent)
        XCTAssertEqual(fixture.span.begins, 0)
        await fixture.host.close()
    }

    func testQueuedGrantWithoutCurrentLocalOffer_IsRejected() async throws {
        let fixture = try ObservationalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let token = fixture.span.offerLocalConsent()
        _ = fixture.span.revokeLocalOffer()
        do {
            _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowObservationalLearning\t\(token)")
            XCTFail("A queued grant after native Stop cannot recreate consent")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("local observational consent action is stale"))
        }
        await fixture.host.observationalOutputAndWait()
        XCTAssertEqual(fixture.span.begins, 0)
        await fixture.host.close()
    }

    func testNativeInvalidationAtReadCompletion_CannotEnterDomain() async throws {
        let fixture = try ObservationalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.allow()
        fixture.span.invalidateOnRead()
        await fixture.host.observationalOutputAndWait()
        let state = try await fixture.host.observationalStateForTest()
        XCTAssertEqual(fixture.span.reads, 1)
        XCTAssertEqual(state.candidates, 0)
        XCTAssertEqual(state.rules, 0)
        await fixture.host.close()
    }

    func testHeldQueue_OldAllowAndStopCannotConsumeOrRevokeNewOffer() async throws {
        let fixture = try ObservationalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = fixture.span.offerLocalConsent()
        let latch = ObservationalConsentLatch()
        let entered = expectation(description: "old Allow is held before Host delivery")
        let queuedA = Task {
            entered.fulfill()
            await latch.wait()
            do {
                _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowObservationalLearning\t\(a)")
                return "accepted"
            } catch {
                return error.localizedDescription
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        let oldStop = fixture.span.revokeLocalOffer()
        let b = fixture.span.offerLocalConsent()
        await latch.release()
        let oldResult = await queuedA.value
        XCTAssertTrue(oldResult.contains("stale"))
        do {
            _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "stopObservationalLearning\t\(oldStop)")
            XCTFail("Queued old Stop must not clear the later local offer")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stale"))
        }
        XCTAssertTrue(fixture.span.consentActionIsCurrent(true, token: b))
        XCTAssertFalse(fixture.span.isCurrent)
        XCTAssertEqual(fixture.span.begins, 0)
        _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowObservationalLearning\t\(b)")
        do {
            _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "stopObservationalLearning\t\(oldStop)")
            XCTFail("Replayed old Stop must not revoke the latest approved session")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stale"))
        }
        let consent = await fixture.host.observationalConsentForTest()
        XCTAssertTrue(consent)
        await fixture.host.observationalOutputAndWait()
        XCTAssertEqual(fixture.span.reads, 1)
        await fixture.host.close()
    }

    func testTokenlessAndMalformedActions_DoNotConsumeCurrentOffer() async throws {
        let fixture = try ObservationalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let token = fixture.span.offerLocalConsent()
        for payload in ["allowObservationalLearning", "allowObservationalLearning\t0",
                        "allowObservationalLearning\t-1", "allowObservationalLearning\t01",
                        "allowObservationalLearning\t\(token)\textra", "allowLearning", "stopLearning"] {
            do {
                _ = try await fixture.host.vocabularyEvent(kind: 3, payload: payload)
                XCTFail("Only the exact current native action may change observational consent")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
        XCTAssertTrue(fixture.span.consentActionIsCurrent(true, token: token))
        XCTAssertEqual(fixture.span.begins, 0)
        _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowObservationalLearning\t\(token)")
        let consent = await fixture.host.observationalConsentForTest()
        XCTAssertTrue(consent)
        await fixture.host.close()
    }

    func testDisclosedConsent_ActualObservedOutputUsesCanonicalPromotionThenStopRevokes() async throws {
        let fixture = try ObservationalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let notice = try await fixture.allow()
        XCTAssertTrue(notice.contains("App-origin"))
        await fixture.host.observationalOutputAndWait()
        var state = try await fixture.host.observationalStateForTest()
        XCTAssertEqual(state.candidates, 1)
        XCTAssertEqual(state.disposition, .observedInsertion)
        await fixture.host.observationalOutputAndWait()
        state = try await fixture.host.observationalStateForTest()
        XCTAssertEqual(state.candidates, 0)
        XCTAssertEqual(state.rules, 1)
        _ = try await fixture.stop()
        let reads = fixture.span.reads
        await fixture.host.observationalOutputAndWait()
        XCTAssertEqual(fixture.span.reads, reads)
        let consent = await fixture.host.observationalConsentForTest()
        XCTAssertFalse(consent)
        await fixture.host.close()
    }

    func testNonObservationalDisposition_CannotLearn() async throws {
        for disposition in [DesktopTextOutputResult.Disposition.confirmedInsertion, .unconfirmedInsertion, .failed] {
            let fixture = try ObservationalFixture(disposition: disposition)
            _ = try await fixture.allow()
            await fixture.host.observationalOutputAndWait()
            XCTAssertEqual(fixture.span.begins, 0)
            let state = try await fixture.host.observationalStateForTest()
            XCTAssertEqual(state.candidates, 0)
            await fixture.host.close()
            try FileManager.default.removeItem(at: fixture.root)
        }
    }

    func testStopDuringHeldObservation_AwaitsTaskAndFencesLateReadback() async throws {
        let fixture = try ObservationalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.allow()
        let entered = expectation(description: "observational wait entered")
        let owned = await fixture.host.startHeldObservationalOutput(entered)
        let pending = try XCTUnwrap(owned)
        await fulfillment(of: [entered], timeout: 3)
        _ = try await fixture.stop()
        await pending.value
        XCTAssertEqual(fixture.span.reads, 0)
        let state = try await fixture.host.observationalStateForTest()
        XCTAssertEqual(state.candidates, 0)
        await fixture.host.close()
    }

    func testCloseDuringHeldObservation_RevokesAndFencesOwnedTask() async throws {
        let fixture = try ObservationalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.host.observationalStateForTest()
        _ = try await fixture.allow()
        let entered = expectation(description: "observational wait entered before close")
        let owned = await fixture.host.startHeldObservationalOutput(entered)
        let pending = try XCTUnwrap(owned)
        await fulfillment(of: [entered], timeout: 3)
        await fixture.host.close()
        await pending.value
        let consent = await fixture.host.observationalConsentForTest()
        XCTAssertFalse(consent)
        XCTAssertEqual(fixture.span.reads, 0)
        XCTAssertGreaterThan(fixture.span.cancels, 0)
    }
}

private actor ObservationalConsentLatch {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

private struct ObservationalFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let span = ObservationalHostSpan()
    let host: DesktopHostController<FakePlatform>
    init(disposition: DesktopTextOutputResult.Disposition = .observedInsertion) throws {
        FakeLog.shared.reset()
        FakeLog.shared.installCorrectionReadback(span)
        host = try DesktopHostController(directory: root, effects: SyntheticEffects(outputDisposition: disposition))
    }
    func allow() async throws -> String {
        let token = span.offerLocalConsent()
        return try await host.vocabularyEvent(kind: 3, payload: "allowObservationalLearning\t\(token)")
    }
    func stop() async throws -> String {
        let token = span.revokeLocalOffer()
        return try await host.vocabularyEvent(kind: 3, payload: "stopObservationalLearning\t\(token)")
    }
}

private final class ObservationalHostSpan: DesktopCorrectionReadback, FakeObservationalConsent, @unchecked Sendable {
    let application: String? = "Synthetic observational target"
    let provenance = DesktopCorrectionProvenance.observationalATSPISpan
    private let lock = NSLock()
    private var beginCount = 0
    private var readCount = 0
    private var cancelCount = 0
    private var nativeCurrent = false
    private var generation: UInt64 = 0
    private var localOffer: UInt64?
    private var revokeAtRead = false
    var isCurrent: Bool { lock.withLock { nativeCurrent } }
    func consentActionIsCurrent(_ allowed: Bool, token: UInt64) -> Bool {
        lock.withLock { token > 0 && token == generation && (!allowed || localOffer == token) }
    }
    func setLocalConsent(_ allowed: Bool, token: UInt64?) -> Bool {
        lock.withLock {
            if let token {
                guard token > 0, token == generation, !allowed || localOffer == token else { return false }
            } else {
                guard !allowed else { return false }
                generation += 1
            }
            localOffer = nil
            nativeCurrent = allowed
            return true
        }
    }
    var begins: Int { lock.withLock { beginCount } }
    var reads: Int { lock.withLock { readCount } }
    var cancels: Int { lock.withLock { cancelCount } }
    func begin(original: String) throws { lock.withLock { beginCount += 1 } }
    func offerLocalConsent() -> UInt64 {
        lock.withLock { generation += 1; localOffer = generation; nativeCurrent = false; return generation }
    }
    func revokeLocalOffer() -> UInt64 {
        lock.withLock { generation += 1; localOffer = nil; nativeCurrent = false; return generation }
    }
    func invalidateOnRead() { lock.withLock { revokeAtRead = true } }
    func read() throws -> String {
        lock.withLock {
            readCount += 1
            if revokeAtRead { nativeCurrent = false }
        }
        return "Susy"
    }
    func cancel() { lock.withLock { cancelCount += 1 } }
}

private struct ObservationalState {
    let candidates: Int
    let rules: Int
    let disposition: DesktopTextOutputResult.Disposition?
}

private extension DesktopHostController where Platform == FakePlatform {
    func observationalConsentForTest() -> Bool { observationalCorrectionConsent }
    func observationalStateForTest() async throws -> ObservationalState {
        let vocabulary = try await vocabularyStore()
        return ObservationalState(
            candidates: await vocabulary.candidates.candidates.count,
            rules: await vocabulary.lexicon.rules.count, disposition: outputSlot.result?.disposition
        )
    }
    func observationalOutputAndWait() async {
        correctionObservationWait = { _ in }
        _ = beginOutput("Susie", output: .init(options: FakeTextOutput(), target: "synthetic"), recordID: UUID())
        await outputSlot.task?.value
        await correctionObservationTask?.value
    }
    func startHeldObservationalOutput(_ entered: XCTestExpectation) async -> Task<Void, Never>? {
        correctionObservationWait = { _ in
            entered.fulfill()
            try await Task.sleep(for: .seconds(60))
        }
        _ = beginOutput("Susie", output: .init(options: FakeTextOutput(), target: "synthetic"), recordID: UUID())
        await outputSlot.task?.value
        return correctionObservationTask
    }
}
