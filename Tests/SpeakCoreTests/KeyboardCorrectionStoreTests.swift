import Foundation
import XCTest
@testable import SpeakCore

/// The keyboard-to-app inbox for learned corrections (F48, #1651).
@MainActor
final class KeyboardCorrectionStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "KeyboardCorrectionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let change = WordChange(type: .replacement, original: "Susie", corrected: "Susy")

    func testProcessedObservationsAreNeverPendingAgain() {
        let store = KeyboardCorrectionStore(defaults: defaults)
        let posted = store.append([change])
        XCTAssertEqual(store.pendingObservations().map(\.change), [change])
        store.markProcessed(posted.map(\.id))
        XCTAssertTrue(store.pendingObservations().isEmpty)

        let next = store.append([change])
        XCTAssertEqual(store.pendingObservations().map(\.id), next.map(\.id))
    }

    func testNothingIsPostedWhileLearningIsOffOrWithoutTheAppGroup() {
        let store = KeyboardCorrectionStore(defaults: defaults)
        store.setLearningEnabled(false)
        XCTAssertFalse(store.isLearningEnabled)
        XCTAssertTrue(store.append([change]).isEmpty)
        XCTAssertTrue(store.pendingObservations().isEmpty)

        let missing = KeyboardCorrectionStore(defaults: nil)
        XCTAssertFalse(missing.isLearningEnabled)
        XCTAssertTrue(missing.append([change]).isEmpty)
    }

    func testTheInboxKeepsOnlyTheNewestObservations() {
        let store = KeyboardCorrectionStore(defaults: defaults)
        for index in 0..<(KeyboardCorrectionStore.capacity + 5) {
            store.append([WordChange(type: .replacement, original: "w\(index)", corrected: "x\(index)")])
        }
        let pending = store.pendingObservations()
        XCTAssertEqual(pending.count, KeyboardCorrectionStore.capacity)
        XCTAssertEqual(pending.first?.original, "w5")
    }

    func testObserverPostsTheEditMadeWhileAnotherKeyboardWasUp() {
        let store = KeyboardCorrectionStore(defaults: defaults)
        let observer = KeyboardCorrectionObserver(store: store, now: { Date(timeIntervalSince1970: 1_000) })
        let document = UUID()
        observer.didInsert("call Susie", into: KeyboardDocumentReads(
            documentIdentifier: document, isSecureField: false, before: "Hi, call Susie", after: ""
        ))
        observer.keyboardDidDisappear()
        observer.keyboardDidAppear(KeyboardDocumentReads(
            documentIdentifier: document, isSecureField: false, before: "Hi, call Susy", after: ""
        ))
        XCTAssertEqual(store.pendingObservations().map(\.change), [change])
        XCTAssertFalse(observer.isWatching)
    }

    func testObserverNeverWatchesASecureFieldOrWithLearningOff() {
        let store = KeyboardCorrectionStore(defaults: defaults)
        let observer = KeyboardCorrectionObserver(store: store)
        observer.didInsert("hunter2", into: KeyboardDocumentReads(
            documentIdentifier: UUID(), isSecureField: true, before: "hunter2", after: ""
        ))
        XCTAssertFalse(observer.isWatching)

        store.setLearningEnabled(false)
        observer.didInsert("call Susie", into: KeyboardDocumentReads(
            documentIdentifier: UUID(), isSecureField: false, before: "call Susie", after: ""
        ))
        XCTAssertFalse(observer.isWatching)
    }
}
