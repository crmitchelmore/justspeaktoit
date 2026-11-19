import Foundation
import XCTest
@testable import SpeakCore

/// The iOS keyboard's edit watch (F48, #1651).
final class KeyboardCorrectionWatcherTests: XCTestCase {
    private let document = UUID()
    private let start = Date(timeIntervalSince1970: 1_000)

    func testLocateFindsTheTextBetweenTheRememberedContext() {
        let context = CorrectionContext.of(before: "Dear team, ", after: " Thanks.")
        let window = CorrectionTextWindow(
            text: "Dear team, meet Susy at noon. Thanks.", reachesStart: true, reachesEnd: true
        )
        XCTAssertEqual(CorrectionSpan.locate(in: window, context: context), "meet Susy at noon.")
    }

    func testLocateRefusesAnAmbiguousOrMissingAnchor() {
        let before = String(repeating: "x", count: 40) + " anchor "
        let context = CorrectionContext.of(before: before, after: "")
        XCTAssertFalse(context.atStart)
        let repeated = context.before + "one" + context.before + "two"
        XCTAssertNil(CorrectionSpan.locate(
            in: CorrectionTextWindow(text: repeated, reachesStart: true, reachesEnd: true), context: context
        ))
        XCTAssertNil(CorrectionSpan.locate(
            in: CorrectionTextWindow(text: "nothing here", reachesStart: true, reachesEnd: true), context: context
        ))
    }

    func testLocateRefusesAnEdgeContextTheReadDidNotReach() {
        let context = CorrectionContext.of(before: "", after: "")
        let window = CorrectionTextWindow(text: "edited text", reachesStart: false, reachesEnd: true)
        XCTAssertNil(CorrectionSpan.locate(in: window, context: context))
        XCTAssertNil(CorrectionSpan.locate(
            in: CorrectionTextWindow(text: "edited text", reachesStart: true, reachesEnd: true),
            context: context, maxUTF16Length: 4
        ))
    }

    func testEditAfterTheKeyboardReturnsReportsTheChangedWords() {
        var watcher = KeyboardCorrectionWatcher()
        watcher.didInsert("call Susie today", documentIdentifier: document, at: start,
                          before: "Hi, call Susie today", after: "")
        watcher.keyboardDidDisappear()
        XCTAssertTrue(watcher.isArmed)
        let changes = sample(&watcher, before: "Hi, call Susy today", now: start + 30)
        XCTAssertEqual(changes.map(\.original), ["Susie"])
        XCTAssertEqual(changes.map(\.corrected), ["Susy"])
        XCTAssertFalse(watcher.isWatching)
    }

    func testUnchangedExpiredOrSecureFieldsLearnNothing() {
        var unchanged = armedWatcher()
        XCTAssertEqual(sample(&unchanged, before: "Hi, call Susie today").count, 0)
        XCTAssertFalse(unchanged.isWatching)

        var expired = armedWatcher()
        XCTAssertEqual(sample(&expired, before: "Hi, call Susy today",
                              now: start + KeyboardCorrectionWatcher.maximumAge + 1).count, 0)
        XCTAssertFalse(expired.isWatching)

        var secure = armedWatcher()
        let secureReads = KeyboardDocumentReads(
            documentIdentifier: document, isSecureField: true, before: "Hi, call Susy today", after: ""
        )
        XCTAssertEqual(secure.sample(secureReads, now: start + 1).count, 0)
        XCTAssertFalse(secure.isWatching)
    }

    func testAnotherFieldKeepsTheWatchUntilTheTranscriptCanBePlaced() {
        var watcher = armedWatcher()
        let elsewhere = KeyboardDocumentReads(
            documentIdentifier: UUID(), isSecureField: false, before: "Unrelated note", after: ""
        )
        let changes = watcher.sample(elsewhere, now: start + 1)
        XCTAssertEqual(changes.count, 0)
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(sample(&watcher, before: "Hi, call Susy today").map(\.corrected), ["Susy"])
    }

    func testNoContextMeansNoWatchOnceTheKeyboardLeaves() {
        var watcher = KeyboardCorrectionWatcher()
        watcher.didInsert("call Susie", documentIdentifier: document, at: start, before: nil, after: nil)
        XCTAssertTrue(watcher.isWatching)
        watcher.documentChanged(documentIdentifier: document, before: "Hi, call Susie", after: "")
        watcher.keyboardDidDisappear()
        XCTAssertTrue(watcher.isArmed)

        var unread = KeyboardCorrectionWatcher()
        unread.didInsert("call Susie", documentIdentifier: document, at: start, before: nil, after: nil)
        unread.keyboardDidDisappear()
        XCTAssertFalse(unread.isWatching)
    }

    private func armedWatcher() -> KeyboardCorrectionWatcher {
        var watcher = KeyboardCorrectionWatcher()
        watcher.didInsert("call Susie today", documentIdentifier: document, at: start,
                          before: "Hi, call Susie today", after: "")
        watcher.keyboardDidDisappear()
        return watcher
    }

    private func sample(
        _ watcher: inout KeyboardCorrectionWatcher, before: String, now: Date? = nil
    ) -> [WordChange] {
        let reads = KeyboardDocumentReads(documentIdentifier: document, isSecureField: false, before: before, after: "")
        return watcher.sample(reads, now: now ?? start + 1)
    }
}
