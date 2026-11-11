import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

/// The presentation and callback code both native windows share. A fake C
/// table stands in for `CWindowsSupport`/`CLinuxSupport`, so these cases pin
/// what either window is sent and what it reports when the window refuses.
final class DesktopNativeWindowPlatformTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        NativeWindowLog.shared.reset()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        NativeWindowLog.shared.reset()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController() throws -> DesktopHostController<NativeTestPlatform> {
        try DesktopHostController<NativeTestPlatform>(directory: root, effects: NativeTestEffects())
    }

    func testVoicePresentation_sendsTheNativeCallsAndReportsRefusals() {
        let log = NativeWindowLog.shared
        NativeTestPlatform.voiceUsage(.init(requestID: "r1", text: "usage", trackingEnabled: true))
        NativeTestPlatform.voiceTextImportCancelled("r2")
        NativeTestPlatform.voiceTextImported(.failure(DesktopHostError(message: "unreadable")), requestID: "r3")
        XCTAssertEqual(log.recorded, [
            "usage|r1|usage|1", "textImport|r2||Text import stopped.", "textImport|r3||unreadable"
        ])
        XCTAssertEqual(log.statusLines, [])

        log.refuses = true
        NativeTestPlatform.voiceUsage(.init(requestID: "r1", text: "usage", trackingEnabled: false))
        NativeTestPlatform.voiceTextImportCancelled("r2")
        NativeTestPlatform.voiceTextImported(.success("text"), requestID: "r3")
        NativeTestPlatform.historyManagement(identifiers: [])
        XCTAssertEqual(log.statusLines, [
            "The Voice usage report could not be shown.",
            "The stopped text import could not be shown.",
            "The text import result could not be shown.",
            "History management could not be refreshed. Saved recordings remain on disk."
        ])
    }

    func testCleanupPreviewRefusal_namesTheHost() {
        NativeWindowLog.shared.refuses = true
        XCTAssertEqual(NativeTestPlatform.beginCleanupPreview(), 7)
        XCTAssertThrowsError(try NativeTestPlatform.cleanupPreview("draft", ticket: 7)) {
            XCTAssertEqual($0.localizedDescription, "Native test host could not enqueue the cleanup preview.")
        }
    }

    func testVoiceKeyEditor_showsNoSecretAndReportsARefusedResult() {
        let log = NativeWindowLog.shared
        let request = UUID()
        NativeTestPlatform.voiceCredential(.failure(.cancelled), requestID: request)
        XCTAssertEqual(log.recorded.count, 1)
        XCTAssertTrue(log.recorded[0].hasPrefix("credential|\(request.uuidString)|"))
        XCTAssertTrue(log.recorded[0].hasSuffix("|-1|0"), "A failed read shows the unavailable state")

        log.refuses = true
        NativeTestPlatform.voiceCredential(.failure(.cancelled), requestID: request)
        XCTAssertEqual(log.statusLines, ["The Voice provider key state could not be shown."])
    }

    func testConfigurationPresent_showsEveryCanonicalFieldThenStopsAtTheFirstRefusal() async throws {
        let snapshot = try await makeController().nativeConfigurationEditorSnapshot()
        var revisions: [(count: Int, revision: String)] = []
        var timing = 0
        let calls = fakeConfigurationCalls { count, revision in revisions.append((count, revision)); return 0 }
        let callback: DesktopNativeConfigurationCallback = { _, _, _, _, _, _ in 0 }
        let shown = DesktopNativeConfiguration.present(
            snapshot, calls: calls, callback: callback, context: nil, applyTiming: { _ in timing += 1 }
        )
        XCTAssertNil(shown)
        XCTAssertEqual(timing, 1)
        XCTAssertEqual(revisions.map(\.count), [DesktopConfiguration.fields.count])
        XCTAssertEqual(revisions.map(\.revision), [snapshot.id])

        var refusedEscape = calls
        refusedEscape.setEscapeCancellation = { _ in -1 }
        XCTAssertEqual(DesktopNativeConfiguration.present(
            snapshot, calls: refusedEscape, callback: callback, context: nil, applyTiming: { _ in timing += 1 }
        ), .escapeCancellation)
        XCTAssertEqual(timing, 1, "Timing is applied only once Escape cancellation is shown")

        let refusedRevision = fakeConfigurationCalls { _, _ in -1 }
        XCTAssertEqual(DesktopNativeConfiguration.present(
            snapshot, calls: refusedRevision, callback: callback, context: nil, applyTiming: { _ in }
        ), .preferences)
    }

    func testConfigurationRows_useTheSnapshotsVoiceTitles() async throws {
        let snapshot = try await makeController().nativeConfigurationEditorSnapshot()
        let strings = DesktopNativeStrings()
        let rows = DesktopNativeConfiguration.rows(snapshot, strings: strings)
        let titles = rows.map { $0.title.map { String(cString: $0) } ?? "" }
        let language = try XCTUnwrap(DesktopNativeConfiguration.languageFieldIndex)
        let quality = try XCTUnwrap(DesktopNativeConfiguration.qualityFieldIndex)
        XCTAssertEqual(titles[language], snapshot.languageTitle)
        XCTAssertEqual(titles[quality], snapshot.qualityTitle)
        for (index, field) in DesktopConfiguration.fields.enumerated() {
            let expected: Int32 = field.enabledBy.flatMap { key in
                DesktopConfiguration.fields.firstIndex { $0.key == key }.map { Int32($0 + 1) }
            } ?? 0
            XCTAssertEqual(rows[index].enabledByField, expected, field.key)
        }
        withExtendedLifetime(strings) {}
    }

    func testLayout_reportsTheRefusedStep() throws {
        let preferences = try DesktopConfiguration()
        let log = NativeWindowLog.shared
        var calls = DesktopNativeLayoutCalls<Int32, String>(
            makeDensity: { $0.isCompact ? 1 : 0 }, setDensity: { _ in 0 },
            makeShortcut: { destination, digit, _ in "\(String(cString: destination!))=\(digit)" },
            setSidebarShortcuts: { rows, count, _ in
                log.record("shortcuts", Array(UnsafeBufferPointer(start: rows, count: count)))
            }
        )
        XCTAssertNil(DesktopNativeConfiguration.presentLayout(preferences, calls: calls))
        XCTAssertEqual(log.recorded.count, 1)
        XCTAssertEqual(log.recorded.first?.split(separator: "|").count, DesktopSidebarShortcut.allCases.count + 1)
        calls.setSidebarShortcuts = { _, _, _ in -1 }
        XCTAssertEqual(DesktopNativeConfiguration.presentLayout(preferences, calls: calls), .sidebarShortcuts)
        calls.setDensity = { _ in -1 }
        XCTAssertEqual(DesktopNativeConfiguration.presentLayout(preferences, calls: calls), .layoutDensity)
    }

    func testLists_copyRowsAndCapSettingsSearch() throws {
        var links: [String] = []
        try DesktopNativeLists.configureAbout(
            for: .linux, link: { "\(String(cString: $0!)) \(String(cString: $1!))" },
            configure: {
                XCTAssertTrue(String(cString: $0!).contains("Linux"))
                links = Array(UnsafeBufferPointer(start: $1, count: $2)); return 0
            }
        )
        XCTAssertEqual(links.count, AppInformationLink.allCases.count)
        XCTAssertThrowsError(try DesktopNativeLists.configureAbout(
            for: .windows, link: { _, _ in 0 }, configure: { _, _, _ in 1 }
        ))

        let rows = DesktopSettingsSearchSession(platform: .linux).results(for: "e", limit: 500)
        var shown = 0
        XCTAssertTrue(DesktopNativeLists.settingsSearchResults(
            rows, row: { title, _, _ in String(cString: title!) }, set: { shown = $1; return 0 }
        ))
        XCTAssertGreaterThan(rows.count, 0)
        XCTAssertEqual(shown, min(rows.count, DesktopNativeLists.maximumSettingsSearchResults))

        var selected: [Int32] = []
        let filter = DesktopHistoryFilter(models: ["b"], errorsOnly: true, fromDay: "2026-01-01")
        XCTAssertFalse(DesktopNativeLists.historyFilters(
            models: ["a", "b"], selection: filter, model: { _, _, chosen in chosen },
            set: { models, count, errors, from, through in
                selected = Array(UnsafeBufferPointer(start: models, count: count))
                XCTAssertEqual(errors, 1)
                XCTAssertEqual(String(cString: from!), "2026-01-01")
                XCTAssertEqual(String(cString: through!), "")
                return -1
            }
        ))
        XCTAssertEqual(selected, [0, 1])
    }

    func testMarkupHelper_passesTheSharedWrapCallback() {
        var wrap: DesktopNativeLists.MarkupWrap?
        var enabled: Int32 = -1
        XCTAssertTrue(DesktopNativeLists.voiceMarkupHelper(
            enabled: true, example: { _, _ in 0 }, set: { enabled = $0; wrap = $3; return 0 }
        ))
        XCTAssertEqual(enabled, 1)
        XCTAssertNotNil(wrap)
    }

    func testNativePage_matchesTheSharedSidebarOrder() {
        XCTAssertEqual(DesktopNativePage.dashboard.rawValue, 0)
        XCTAssertEqual(DesktopNativePage.about.rawValue, 11)
        let pages = DesktopSettingsDestination.allCases.map(DesktopNativePage.init)
        XCTAssertEqual(Set(pages).count, DesktopSettingsDestination.allCases.count)
        XCTAssertFalse(pages.contains(.dashboard))
        XCTAssertFalse(pages.contains(.history))
    }

    // MARK: Holder callbacks

    func testCredentialEvents_rejectMalformedArgumentsAndQueueValidOnes() throws {
        let holder = NativeTestHolder(controller: try makeController())
        let context = NativeCallbackContext(holder)
        defer { context.release() }
        NativeTestHolder.voiceCredentialEvent([nil, nil], context: context.pointer)
        XCTAssertEqual(NativeWindowLog.shared.statusLines, ["The Voice key request was malformed."])
        XCTAssertEqual(holder.queuedCount, 0)

        NativeTestHolder.voiceCredentialEvent([nil, nil, nil, nil, nil, nil], context: context.pointer)
        XCTAssertEqual(holder.queuedCount, 0, "An empty operation is not a credential message")
        XCTAssertEqual(NativeWindowLog.shared.statusLines.count, 2)

        context.unregister()
        NativeTestHolder.voiceCredentialEvent([nil, nil], context: context.pointer)
        XCTAssertEqual(NativeWindowLog.shared.statusLines.count, 2, "An ended registration does nothing")
    }

    func testConfigurationEvent_validatesSynchronouslyAndAppliesInSettingsOrder() async throws {
        let holder = NativeTestHolder(controller: try makeController())
        let context = NativeCallbackContext(holder)
        defer { context.release() }
        let performed = NativeWindowLog.shared
        var buffer = [CChar](repeating: 0, count: 128)
        let malformed = NativeTestHolder.configurationEditorEvent(
            action: 6, values: ["not a UUID"], context: context.pointer, errorBuffer: &buffer, capacity: buffer.count
        )
        XCTAssertEqual(malformed, -1)
        XCTAssertFalse(String(cString: buffer).isEmpty)
        XCTAssertEqual(holder.queuedCount, 0)

        let applied = NativeTestHolder.configurationEditorEvent(
            action: 1, values: ["/tmp/import.json"], context: context.pointer, errorBuffer: &buffer,
            capacity: buffer.count
        )
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(holder.queuedCount, 1)
        XCTAssertEqual(performed.recorded, [], "Nothing runs before the settings queue does")
        await holder.drainSettings()
        XCTAssertEqual(performed.recorded, ["perform|1", "redisplay"])
        XCTAssertEqual(performed.statusLines, ["Import failed."])

        context.unregister()
        XCTAssertEqual(NativeTestHolder.configurationEditorEvent(
            action: 1, values: [], context: context.pointer, errorBuffer: nil, capacity: 0
        ), -1)
    }

    func testVoiceSourceEvent_joinsHistoryOrderForPlaybackEvents() throws {
        let holder = NativeTestHolder(controller: try makeController())
        holder.submitVoiceSource(.event(.stop))
        holder.submitVoiceSource(.usageTracking(true, requestID: "r"))
        XCTAssertEqual(holder.historyEvents, [.stop])
        XCTAssertEqual(holder.queuedCount, 1)
    }

    func testHandlerSlot_reportsConfigurationAndDetachFailures() throws {
        let holder = NativeTestHolder(controller: try makeController())
        var attachResults = [false]
        let refused = DesktopNativeHandlerSlot<NativeTestHolder>("The test callback") { _ in
            attachResults.removeFirst()
        }
        XCTAssertThrowsError(try refused.begin(holder)) {
            XCTAssertEqual($0.localizedDescription, "The test callback could not be configured.")
        }

        attachResults = [true, false]
        let stuck = DesktopNativeHandlerSlot<NativeTestHolder>("The test callback") { _ in
            attachResults.removeFirst()
        }
        let registration = try stuck.begin(holder)
        stuck.end(registration)
        XCTAssertEqual(NativeWindowLog.shared.statusLines, ["The test callback could not be detached safely."])
        XCTAssertNotNil(registration.value, "A slot native code may still call keeps its holder")
        registration.unregister()
    }

    func testHandlerSlot_freesADetachedRegistrationBecauseTheNativeSetterIsQuiescent() throws {
        let holder = NativeTestHolder(controller: try makeController())
        let slot = DesktopNativeHandlerSlot<NativeTestHolder>("The test callback") { _ in true }
        weak var box: NativeCallbackContext<NativeTestHolder>?
        do {
            let registration = try slot.begin(holder)
            box = registration
            slot.end(registration)
        }
        XCTAssertNil(box, "No empty box is left behind for a quiescent native slot")
        XCTAssertEqual(NativeWindowLog.shared.statusLines, [])
    }

    // MARK: Helpers

    private func fakeConfigurationCalls(
        revision: @escaping (Int, String) -> Int32
    ) -> DesktopNativeConfigurationCalls<Int32> {
        DesktopNativeConfigurationCalls(
            makeField: { $0.isBoolean },
            setRevision: { _, count, _, _, _, _, id in revision(count, String(cString: id!)) },
            setFieldTitle: { _, _ in 0 }, setFieldEnabled: { _, _ in 0 }, setEscapeCancellation: { _ in 0 }
        )
    }
}
