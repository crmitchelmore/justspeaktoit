#if os(iOS)
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import SpeakiOSLib

@MainActor
final class TranscriptClipboardTests: XCTestCase {
    func testCopyWritesOneUTF8ItemWithEveryFiniteLifetime() {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)

        for lifetime in TranscriptClipboardLifetime.allCases {
            let pasteboard = RecordingTranscriptPasteboard()
            let clipboard = TranscriptClipboard(
                pasteboard: pasteboard,
                now: { instant },
                policy: { TranscriptClipboardPolicy(lifetime: lifetime, allowsUniversalClipboard: false) }
            )

            XCTAssertTrue(clipboard.copy("  exact transcript\n"))
            XCTAssertEqual(pasteboard.writes.count, 1)
            XCTAssertEqual(
                pasteboard.writes[0].items[0][UTType.utf8PlainText.identifier] as? String,
                "  exact transcript\n"
            )
            XCTAssertEqual(pasteboard.writes[0].items.count, 1)
            XCTAssertEqual(pasteboard.writes[0].options[.localOnly] as? Bool, true)
            XCTAssertEqual(
                pasteboard.writes[0].options[.expirationDate] as? Date,
                instant.addingTimeInterval(TimeInterval(lifetime.rawValue))
            )
        }
    }

    func testExplicitUniversalClipboardChoiceAndChangedPolicyApplyToNextWrite() {
        let pasteboard = RecordingTranscriptPasteboard()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = TranscriptClipboardPolicy.defaultValue
        let clipboard = TranscriptClipboard(
            pasteboard: pasteboard,
            now: { now },
            policy: { policy }
        )

        XCTAssertTrue(clipboard.copy("first"))
        XCTAssertEqual(
            pasteboard.writes[0].options[.expirationDate] as? Date,
            now.addingTimeInterval(300)
        )
        now.addTimeInterval(10)
        policy = TranscriptClipboardPolicy(lifetime: .fifteenMinutes, allowsUniversalClipboard: true)
        XCTAssertTrue(clipboard.copy("second"))

        XCTAssertEqual(pasteboard.writes[0].options[.localOnly] as? Bool, true)
        XCTAssertEqual(pasteboard.writes[1].options[.localOnly] as? Bool, false)
        XCTAssertEqual(
            pasteboard.writes[1].options[.expirationDate] as? Date,
            now.addingTimeInterval(900)
        )
    }

    func testCopyReportsObservedChangeAndEmptyTextMakesNoWrite() {
        let pasteboard = RecordingTranscriptPasteboard()
        let clipboard = self.makeClipboard(pasteboard: pasteboard)

        XCTAssertFalse(clipboard.copy(""))
        XCTAssertTrue(pasteboard.writes.isEmpty)

        pasteboard.acceptsWrites = false
        XCTAssertFalse(clipboard.copy("not accepted"))
        XCTAssertEqual(pasteboard.writes.count, 1)
    }

    func testNewerExternalItemIsNeverTouchedAfterCopyReturns() {
        let pasteboard = RecordingTranscriptPasteboard()
        let clipboard = self.makeClipboard(pasteboard: pasteboard)

        XCTAssertTrue(clipboard.copy("transcript"))
        pasteboard.copyExternalItem("newer item")

        XCTAssertEqual(pasteboard.currentText, "newer item")
        XCTAssertEqual(pasteboard.writes.count, 1)
    }

    func testPolicyRejectsMissingWrongAndUnsupportedPersistedTypes() {
        let invalidValues: [Any?] = [nil, "300", -300, 1, 301, 300.5, true]
        for value in invalidValues {
            XCTAssertEqual(
                TranscriptClipboardPolicy(
                    storedLifetime: value,
                    storedAllowsUniversalClipboard: 1
                ),
                .defaultValue
            )
        }

        XCTAssertEqual(
            TranscriptClipboardPolicy(storedLifetime: 60, storedAllowsUniversalClipboard: false),
            TranscriptClipboardPolicy(lifetime: .oneMinute, allowsUniversalClipboard: false)
        )
        XCTAssertEqual(
            TranscriptClipboardPolicy(storedLifetime: 900, storedAllowsUniversalClipboard: true),
            TranscriptClipboardPolicy(lifetime: .fifteenMinutes, allowsUniversalClipboard: true)
        )
    }

    func testSettingsPersistChoicesAcrossRestartWithoutAcknowledgingNotice() {
        let defaults = self.makeDefaults()
        let first = AppSettings(defaults: defaults, loadsSecureStorage: false)

        XCTAssertEqual(first.transcriptClipboardLifetime, .fiveMinutes)
        XCTAssertFalse(first.transcriptAllowsUniversalClipboard)
        XCTAssertTrue(first.isTranscriptClipboardNoticePending)

        first.transcriptClipboardLifetime = .oneMinute
        first.transcriptAllowsUniversalClipboard = false

        let restarted = AppSettings(defaults: defaults, loadsSecureStorage: false)
        XCTAssertEqual(restarted.transcriptClipboardLifetime, .oneMinute)
        XCTAssertFalse(restarted.transcriptAllowsUniversalClipboard)
        XCTAssertTrue(restarted.isTranscriptClipboardNoticePending)

        restarted.transcriptClipboardLifetime = .fifteenMinutes
        restarted.transcriptAllowsUniversalClipboard = true
        _ = self.makeClipboard(policy: { restarted.transcriptClipboardPolicy }).copy("headless copy")

        let afterHeadlessCopy = AppSettings(defaults: defaults, loadsSecureStorage: false)
        XCTAssertEqual(afterHeadlessCopy.transcriptClipboardLifetime, .fifteenMinutes)
        XCTAssertTrue(afterHeadlessCopy.transcriptAllowsUniversalClipboard)
        XCTAssertTrue(afterHeadlessCopy.isTranscriptClipboardNoticePending)

        afterHeadlessCopy.acknowledgeTranscriptClipboardNotice()
        XCTAssertFalse(afterHeadlessCopy.isTranscriptClipboardNoticePending)
        let afterAcknowledgement = AppSettings(defaults: defaults, loadsSecureStorage: false)
        XCTAssertFalse(afterAcknowledgement.isTranscriptClipboardNoticePending)
    }

    func testSettingsRejectMalformedStoredPolicyAndNoticeValues() {
        let defaults = self.makeDefaults()
        defaults.set("900", forKey: AppSettings.DefaultsKey.transcriptClipboardLifetimeSeconds.rawValue)
        defaults.set(1, forKey: AppSettings.DefaultsKey.transcriptUniversalClipboard.rawValue)
        defaults.set(true, forKey: AppSettings.DefaultsKey.transcriptClipboardNoticeVersion.rawValue)

        let settings = AppSettings(defaults: defaults, loadsSecureStorage: false)

        XCTAssertEqual(settings.transcriptClipboardLifetime, .fiveMinutes)
        XCTAssertFalse(settings.transcriptAllowsUniversalClipboard)
        XCTAssertTrue(settings.isTranscriptClipboardNoticePending)
    }

    func testPrivacySummaryAlwaysStatesEffectiveChoiceAndLimits() {
        let settings = AppSettings(defaults: self.makeDefaults(), loadsSecureStorage: false)

        XCTAssertTrue(settings.transcriptClipboardPrivacySummary.contains("after 5 minutes"))
        XCTAssertTrue(settings.transcriptClipboardPrivacySummary.contains("Universal Clipboard is off"))
        XCTAssertTrue(settings.transcriptClipboardPrivacySummary.contains("does not delete History"))
        XCTAssertTrue(settings.transcriptClipboardPrivacySummary.contains("not guaranteed"))

        settings.transcriptClipboardLifetime = .fifteenMinutes
        settings.transcriptAllowsUniversalClipboard = true
        XCTAssertTrue(settings.transcriptClipboardPrivacySummary.contains("after 15 minutes"))
        XCTAssertTrue(settings.transcriptClipboardPrivacySummary.contains("Universal Clipboard is on"))
    }

    @available(iOS 18, *)
    func testCompletionCopyUsesAdapterResult() {
        let accepting = RecordingTranscriptPasteboard()
        XCTAssertTrue(
            CopyLastTranscriptIntent.copyConfirmingChangeCount(
                "completion",
                clipboard: self.makeClipboard(pasteboard: accepting)
            )
        )

        let refusing = RecordingTranscriptPasteboard()
        refusing.acceptsWrites = false
        XCTAssertFalse(
            CopyLastTranscriptIntent.copyConfirmingChangeCount(
                "completion",
                clipboard: self.makeClipboard(pasteboard: refusing)
            )
        )
    }

    func testExplicitIntentHelpersPreserveSentenceAndFullTranscriptContent() {
        let pasteboard = RecordingTranscriptPasteboard()
        let clipboard = self.makeClipboard(pasteboard: pasteboard)

        XCTAssertTrue(CopyLastSentenceIntent.copy("Last sentence.", clipboard: clipboard))
        XCTAssertTrue(CopyFullTranscriptIntent.copy("Full\ntranscript", clipboard: clipboard))

        XCTAssertEqual(
            pasteboard.writes.compactMap { $0.items[0][UTType.utf8PlainText.identifier] as? String },
            ["Last sentence.", "Full\ntranscript"]
        )
    }

    func testAutomaticRawWriterDelegatesWithoutChangingText() {
        let pasteboard = RecordingTranscriptPasteboard()
        let clipboard = self.makeClipboard(pasteboard: pasteboard)

        SystemPolishPasteboard(clipboard: clipboard).write("  raw transcript  ")

        XCTAssertEqual(
            pasteboard.writes.first?.items[0][UTType.utf8PlainText.identifier] as? String,
            "  raw transcript  "
        )
    }

    private func makeClipboard(
        pasteboard: RecordingTranscriptPasteboard = RecordingTranscriptPasteboard(),
        policy: @escaping () -> TranscriptClipboardPolicy = { .defaultValue }
    ) -> TranscriptClipboard {
        TranscriptClipboard(
            pasteboard: pasteboard,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            policy: policy
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TranscriptClipboardTests.\(UUID().uuidString)"
        self.addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
}

@MainActor
private final class RecordingTranscriptPasteboard: TranscriptPasteboard {
    struct Write {
        let items: [[String: Any]]
        let options: [UIPasteboard.OptionsKey: Any]
    }

    var acceptsWrites = true
    private(set) var changeCount = 0
    private(set) var writes: [Write] = []
    private(set) var currentText: String?

    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
        self.writes.append(Write(items: items, options: options))
        guard self.acceptsWrites else { return }
        self.changeCount += 1
        self.currentText = items.first?[UTType.utf8PlainText.identifier] as? String
    }

    func copyExternalItem(_ text: String) {
        self.changeCount += 1
        self.currentText = text
    }
}
#endif
