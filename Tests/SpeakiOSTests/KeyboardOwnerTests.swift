#if IOS_KEYBOARD_FEATURE
import Foundation
import SpeakCore
import XCTest

/// The delivery owner on its own, driven through the context closure the view
/// model supplies rather than through a whole keyboard appearance.
@MainActor
final class KeyboardDeliveryCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var store: KeyboardDeliveryStore!
    private var inserted: [String] = []
    private var handBacks = 0
    private var documentIdentifier = UUID()
    private var isSecureField = false
    private var isBlocked = false
    private var captureInFlight = false
    private var activeInputModeCount = 2
    private var onInsert: (() -> Void)?

    override func setUp() async throws {
        suiteName = "KeyboardDeliveryCoordinatorTests.\(UUID().uuidString)"
        store = KeyboardDeliveryStore(defaults: UserDefaults(suiteName: suiteName), announceStatusChange: {})
        inserted = []
        handBacks = 0
        documentIdentifier = UUID()
        isSecureField = false
        isBlocked = false
        captureInFlight = false
        activeInputModeCount = 2
        onInsert = nil
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeCoordinator() -> KeyboardDeliveryCoordinator {
        let coordinator = KeyboardDeliveryCoordinator(store: store)
        coordinator.context = { [unowned self] in
            KeyboardDeliveryContext(
                isBlocked: isBlocked,
                documentIdentifier: documentIdentifier,
                isSecureField: isSecureField,
                captureInFlight: captureInFlight,
                activeInputModeCount: activeInputModeCount,
                insertText: { [unowned self] text in
                    inserted.append(text)
                    onInsert?()
                },
                handBack: { [unowned self] in handBacks += 1 }
            )
        }
        coordinator.beginAppearance()
        return coordinator
    }

    @discardableResult
    private func publishOffer(
        _ text: String, mode: KeyboardPickupOffer.Mode, origin: UUID? = nil
    ) -> KeyboardPickupOffer {
        let now = Date()
        let offer = KeyboardPickupOffer(
            text: text, source: .app, mode: mode, createdAt: now,
            expiresAt: now.addingTimeInterval(60), originDocumentIdentifier: origin
        )
        store.publishOffer(offer)
        return offer
    }

    func testRefreshBeforeTheAppearanceBegins_neitherAdvertisesNorOffers() {
        let coordinator = KeyboardDeliveryCoordinator(store: store)
        coordinator.context = { XCTFail("an inactive appearance must not read its context"); return nil }
        publishOffer("late", mode: .latePickup)

        coordinator.refresh()

        XCTAssertEqual(coordinator.offering, .none)
        XCTAssertNil(store.openTarget())
    }

    func testRefreshWithoutAContext_dropsTheOffering() {
        let coordinator = makeCoordinator()
        publishOffer("late", mode: .latePickup)
        coordinator.refresh()
        XCTAssertNotEqual(coordinator.offering, .none)

        coordinator.context = { nil }
        coordinator.refresh()
        XCTAssertEqual(coordinator.offering, .none)
    }

    func testRefresh_advertisesTheOpenDocumentAndReportsEveryOfferingChange() {
        let coordinator = makeCoordinator()
        var reported: [KeyboardPickupPolicy.Offering] = []
        coordinator.onOfferingChange = { reported.append($0) }

        coordinator.refresh()

        XCTAssertEqual(store.openTarget()?.documentIdentifier, documentIdentifier)
        XCTAssertEqual(reported, [.none], "republished on every assignment, as the view model used to")
    }

    func testBlockedKeyboard_neitherAdvertisesNorOffers() {
        isBlocked = true
        let coordinator = makeCoordinator()
        publishOffer("late", mode: .latePickup)

        coordinator.refresh()

        XCTAssertEqual(coordinator.offering, .none)
        XCTAssertNil(store.openTarget())
    }

    func testSecureField_withdrawsAnEarlierAdvertisement() {
        let coordinator = makeCoordinator()
        coordinator.refresh()
        XCTAssertNotNil(store.openTarget())

        isSecureField = true
        coordinator.refresh()

        XCTAssertNil(store.openTarget())
        XCTAssertEqual(coordinator.offering, .none)
    }

    func testTargetedOffer_insertsOnceClaimsAndHandsBack() {
        let coordinator = makeCoordinator()
        let offer = publishOffer("aimed", mode: .targetedInsert, origin: documentIdentifier)
        // The insertion calls back into the keyboard, which refreshes again.
        onInsert = { coordinator.refresh() }

        coordinator.refresh()
        coordinator.refresh()

        XCTAssertEqual(inserted, ["aimed"])
        XCTAssertEqual(store.claim()?.offerID, offer.offerID)
        XCTAssertEqual(coordinator.offering, .none)
        XCTAssertEqual(handBacks, 1)
    }

    func testHandBack_isWithheldUnlessExactlyTwoKeyboardsAreEnabled() {
        activeInputModeCount = 3
        let coordinator = makeCoordinator()
        publishOffer("aimed", mode: .targetedInsert, origin: documentIdentifier)

        coordinator.refresh()

        XCTAssertEqual(inserted, ["aimed"])
        XCTAssertEqual(handBacks, 0)
    }

    func testCaptureInFlight_holdsBackAnOffer() {
        captureInFlight = true
        let coordinator = makeCoordinator()
        publishOffer("aimed", mode: .targetedInsert, origin: documentIdentifier)

        coordinator.refresh()

        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(coordinator.offering, .none)
    }

    func testLatePickupChip_insertsOnlyWhenTapped() {
        let coordinator = makeCoordinator()
        let offer = publishOffer("later", mode: .latePickup)

        coordinator.refresh()
        guard case let .chip(chip) = coordinator.offering else { return XCTFail("expected a chip") }
        XCTAssertEqual(chip.offerID, offer.offerID)
        XCTAssertTrue(inserted.isEmpty)

        coordinator.insertPendingPickup()
        XCTAssertEqual(inserted, ["later"])
        XCTAssertEqual(store.claim()?.offerID, offer.offerID)
        XCTAssertEqual(coordinator.offering, .none)
    }

    func testDismissingTheChip_claimsItWithoutInserting() {
        let coordinator = makeCoordinator()
        let offer = publishOffer("later", mode: .latePickup)
        coordinator.refresh()

        coordinator.dismissPendingPickup()
        coordinator.refresh()

        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(store.claim()?.offerID, offer.offerID)
        XCTAssertEqual(coordinator.offering, .none)
    }

    func testPreferencesChangedWhileOnScreen_applyOnTheNextRefresh() {
        let coordinator = makeCoordinator()
        publishOffer("matching", mode: .latePickup, origin: documentIdentifier)
        coordinator.refresh()
        XCTAssertTrue(inserted.isEmpty, "matching late pickups wait for a tap by default")

        store.publishPreferences(KeyboardDeliveryPreferences(autoInsertsMatchingPickup: true))
        coordinator.refresh()

        XCTAssertEqual(coordinator.preferences.autoInsertsMatchingPickup, true)
        XCTAssertEqual(inserted, ["matching"])
    }

    func testDeactivate_withdrawsTheTargetAndIgnoresLaterRefreshes() {
        let coordinator = makeCoordinator()
        publishOffer("later", mode: .latePickup)
        coordinator.refresh()

        coordinator.deactivate()
        coordinator.refresh()

        XCTAssertNil(store.openTarget())
        XCTAssertEqual(coordinator.offering, .none)
    }
}

/// The direct-capture owner with a scripted engine and an in-memory field.
@MainActor
final class KeyboardDirectCaptureSessionTests: XCTestCase {
    private final class ScriptedEngine: KeyboardDictationEngineProtocol {
        var onEvent: ((UUID, KeyboardDictationMachine.Event) -> Void)?
        private(set) var started: [(runID: UUID, locale: String)] = []
        private(set) var stopped: [UUID] = []
        private(set) var cancelled: [UUID] = []

        func start(runID: UUID, localeIdentifier: String) { started.append((runID, localeIdentifier)) }
        func stop(runID: UUID) { stopped.append(runID) }
        func cancel(runID: UUID) { cancelled.append(runID) }
        func emit(_ event: KeyboardDictationMachine.Event, for runID: UUID) { onEvent?(runID, event) }
    }

    private final class Field {
        var before: String
        init(_ before: String) { self.before = before }
    }

    private func attachDocument(to session: KeyboardDirectCaptureSession, field: Field) {
        session.attach(
            KeyboardDocumentSession(
                insertText: { field.before += $0 },
                deleteBackward: { if !field.before.isEmpty { field.before.removeLast() } },
                contextBeforeInput: { field.before },
                contextAfterInput: { "" }
            )
        )
    }

    func testMicTap_startsARunInTheResolvedLocaleAndStreamsIntoTheField() throws {
        let engine = ScriptedEngine()
        let session = KeyboardDirectCaptureSession(engine: engine)
        let field = Field("Host")
        attachDocument(to: session, field: field)
        session.localeIdentifier = { "en-GB" }
        var states: [KeyboardDictationMachine.State] = []
        session.onStateChange = { state, _ in states.append(state) }

        session.dispatch(.micTapped)
        let run = try XCTUnwrap(engine.started.first)
        engine.emit(.captureStarted, for: run.runID)
        engine.emit(.hypothesis("hello"), for: run.runID)

        XCTAssertEqual(run.locale, "en-GB")
        XCTAssertEqual(states, [.starting, .recording, .recording])
        XCTAssertEqual(field.before, "Host hello")
        XCTAssertEqual(session.liveText, "hello")
        XCTAssertTrue(session.isCapturing)
    }

    func testStopTap_stopsTheActiveRunAndAFinalTranscriptEndsIt() throws {
        let engine = ScriptedEngine()
        let session = KeyboardDirectCaptureSession(engine: engine)
        let field = Field("")
        attachDocument(to: session, field: field)

        session.dispatch(.micTapped)
        let runID = try XCTUnwrap(engine.started.first?.runID)
        engine.emit(.captureStarted, for: runID)
        session.dispatch(.stopTapped)
        engine.emit(.finalized("done"), for: runID)
        // The finished run's identity is released, so a straggler is dropped.
        engine.emit(.hypothesis("late"), for: runID)

        XCTAssertEqual(engine.stopped, [runID])
        XCTAssertEqual(session.state, .finished)
        XCTAssertEqual(field.before, "done")
    }

    func testEventsFromAnotherRun_neverReachTheMachine() throws {
        let engine = ScriptedEngine()
        let session = KeyboardDirectCaptureSession(engine: engine)
        attachDocument(to: session, field: Field(""))

        session.dispatch(.micTapped)
        engine.emit(.captureStarted, for: UUID())

        XCTAssertEqual(session.state, .starting)
    }

    func testCancelledRun_isCancelledOnTheEngineAndItsLateEventsAreDropped() throws {
        let engine = ScriptedEngine()
        let session = KeyboardDirectCaptureSession(engine: engine)
        attachDocument(to: session, field: Field(""))
        var cancellations = 0
        session.onCaptureCancelled = { cancellations += 1 }

        session.dispatch(.micTapped)
        let runID = try XCTUnwrap(engine.started.first?.runID)
        session.dispatch(.dismissed)
        engine.emit(.captureStarted, for: runID)

        XCTAssertEqual(engine.cancelled, [runID])
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(session.state, .idle)
    }

    func testEditThatCannotBeApplied_endsTheRunAsATargetChange() throws {
        let engine = ScriptedEngine()
        let session = KeyboardDirectCaptureSession(engine: engine)

        session.dispatch(.micTapped)
        let runID = try XCTUnwrap(engine.started.first?.runID)
        engine.emit(.captureStarted, for: runID)
        engine.emit(.hypothesis("lost"), for: runID)
        engine.emit(.hypothesis("lost again"), for: runID)

        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(engine.cancelled, [runID])
    }

    func testReset_startsAFreshMachineAndReportsIt() {
        let session = KeyboardDirectCaptureSession(engine: ScriptedEngine())
        attachDocument(to: session, field: Field(""))
        session.dispatch(.micTapped)
        var reported: [(KeyboardDictationMachine.State, String)] = []
        session.onStateChange = { reported.append(($0, $1)) }

        session.reset()

        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(reported.map(\.0), [.idle])
        XCTAssertEqual(reported.map(\.1), [""])
    }

    func testDetachedDocument_isNoLongerCurrent() {
        let session = KeyboardDirectCaptureSession(engine: ScriptedEngine())
        let field = Field("Host")
        attachDocument(to: session, field: field)
        session.dispatch(.micTapped)
        XCTAssertTrue(session.documentAnchorIsCurrent)

        session.detachDocument()

        XCTAssertFalse(session.documentAnchorIsCurrent)
    }
}
#endif
