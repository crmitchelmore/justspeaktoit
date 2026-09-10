#if os(iOS)
import AppIntents
import Foundation
import XCTest

@testable import SpeakiOSLib
import SpeakCore

/// The half of the gallery guarantee that can only be checked where AppIntents
/// exists (issue #1015): **every action a recipe names is an action this app
/// actually ships, under exactly that name.** A gallery entry that sends the
/// user searching Shortcuts for an action that was renamed is worse than no
/// entry at all, so a rename has to break the build here.
final class AutomationGalleryIntentTests: XCTestCase {
    /// Every intent that appears in the gallery vocabulary, paired with the
    /// title Shortcuts shows for it.
    @available(iOS 18, *)
    private var shippedTitles: [AutomationAction: String] {
        [
            .dictate: String(localized: DictateIntent.title),
            .startRecording: String(localized: StartTranscriptionIntent.title),
            .toggleRecording: String(localized: StartTranscriptionRecordingIntent.title),
            .stopRecording: String(localized: StopTranscriptionRecordingIntent.title),
            .stopDictationAndGetText: String(localized: StopDictationIntent.title),
            .transcribeAudioFile: String(localized: TranscribeAudioFileIntent.title),
            .polishText: String(localized: PolishTextIntent.title),
            .getLastTranscription: String(localized: GetLastTranscriptionIntent.title)
        ]
    }

    func testEveryGalleryActionMatchesAShippedIntentTitle() throws {
        guard #available(iOS 18, *) else {
            throw XCTSkip("The Dictate and Stop Dictation intents need iOS 18.")
        }
        for action in AutomationAction.allCases {
            XCTAssertEqual(
                shippedTitles[action],
                action.title,
                "The gallery calls this action \"\(action.title)\" but Shortcuts does not"
            )
        }
    }

    func testEveryActionARecipeReferencesIsCovered() throws {
        guard #available(iOS 18, *) else {
            throw XCTSkip("The Dictate and Stop Dictation intents need iOS 18.")
        }
        for action in AutomationGallery.referencedActions {
            XCTAssertNotNil(shippedTitles[action], "\(action.title) is referenced but not shipped")
        }
    }

    // MARK: - The backwards-compatibility guarantee

    /// A Shortcut saved before `Wait For Polish` existed passes nothing for it,
    /// so it must default to off — which is exactly the behaviour it had:
    /// return the raw transcript the moment the recording stops.
    func testWaitForPolishDefaultsToOffOnEveryReturningIntent() throws {
        guard #available(iOS 18, *) else {
            throw XCTSkip("Both returning intents need iOS 18.")
        }
        XCTAssertFalse(StopDictationIntent().waitForPolish)
        XCTAssertFalse(DictateIntent().waitForPolish)
    }

    /// The same guarantee for the file action's new overrides: unset means
    /// "use Settings", which is what the action did before they existed.
    func testTranscribeAudioFileOverridesStartUnset() {
        let intent = TranscribeAudioFileIntent()
        XCTAssertNil(intent.language)
        XCTAssertNil(intent.model)
    }

    func testUnsetFileOverridesResolveToNoOverridesAtAll() throws {
        let intent = TranscribeAudioFileIntent()
        let resolved = try CaptureParameterResolution.resolve(
            language: intent.language,
            model: intent.model
        )
        XCTAssertEqual(resolved, .none)
    }

    /// The file action refuses a language it does not have rather than
    /// transcribing in a different one — #1076's rule, applied to files.
    func testAnUnknownLanguageOnTheFileActionIsRefused() {
        XCTAssertThrowsError(
            try CaptureParameterResolution.resolve(language: "Klingon", model: nil)
        ) {
            XCTAssertEqual($0 as? CaptureParameterFailure, .unknownLanguage)
        }
    }

    /// Shared recordings and Shortcuts-picked files are judged by one unit, so
    /// the Share Sheet and the file action can never disagree about a file.
    func testTheFileActionAndTheShareSheetShareOneFormatList() throws {
        for fileExtension in AutomationIntentSupport.supportedAudioExtensions {
            XCTAssertNoThrow(
                try SharedAudioImport.evaluate(
                    SharedAudioCandidate(filename: "memo.\(fileExtension)", byteCount: 1)
                )
            )
            XCTAssertNoThrow(
                try AutomationIntentSupport.validatedAudioExtension(
                    forFilename: "memo.\(fileExtension)"
                )
            )
        }
    }
}
#endif

#if os(iOS)
/// A shared recording may only be acknowledged once it is durably in History,
/// and replaying one inbox item must not create a second entry.
@MainActor
final class SharedRecordingDurabilityTests: XCTestCase {
    private var root = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The entry carries the inbox item's own id, so a replay updates the same
    /// row instead of adding another. This is the property the importer relies
    /// on when it deletes the staged copy.
    func testReplayingTheSameInboxItemDoesNotAddASecondHistoryEntry() throws {
        let history = iOSHistoryManager.shared
        history.ensureLoaded()
        let inboxItemID = UUID()
        let before = history.items.count

        let first = iOSHistoryItem(
            id: inboxItemID,
            transcription: "shared recording",
            model: "test/model",
            duration: 1,
            wordCount: 2
        )
        XCTAssertTrue(history.upsertReportingDurability(first))
        let replay = iOSHistoryItem(
            id: inboxItemID,
            transcription: "shared recording",
            model: "test/model",
            duration: 1,
            wordCount: 2
        )
        XCTAssertTrue(history.upsertReportingDurability(replay))

        XCTAssertEqual(history.items.filter { $0.id == inboxItemID }.count, 1)
        XCTAssertEqual(history.items.count, before + 1)
        history.remove(first)
    }

    func testEveryImportFailureHasAUserFacingMessage() {
        for failure in [SharedRecordingImporter.ImportFailure.noSpeech, .notSaved] {
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true, "\(failure) has no message")
        }
    }
}
#endif
