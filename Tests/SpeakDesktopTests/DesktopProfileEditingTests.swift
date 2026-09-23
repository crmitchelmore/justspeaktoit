import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

/// What the native desktop editor stores, preserves and refuses.
final class DesktopProfileEditingTests: XCTestCase {
    private let catalogue = DesktopProfileEditing.Catalogue(capabilities: .shared)
    private let notepad = #"C:\Windows\System32\notepad.exe"#
    private let code = #"C:\Users\Alex\AppData\Local\Programs\Microsoft VS Code\Code.exe"#

    private var batchIndex: Int { catalogue.batchModels.count > 1 ? 1 : 0 }
    private var polishIndex: Int { catalogue.polishModels.count > 1 ? 1 : 0 }
    private var languageIndex: Int { catalogue.languages.firstIndex { $0.id == "en_GB" } ?? 0 }

    // MARK: - Drafts from profiles

    func testDraftReflectsCatalogueChoicesAndPreservesWhatItCannotShow() {
        let shown = DictationProfile(
            name: "Shown",
            matchers: [.windowsExecutablePath(notepad), .bundleID("com.apple.Notes")],
            transcriptionModelID: catalogue.batchModels[batchIndex].id,
            polishEnabled: true,
            polishModelID: catalogue.polishModels[polishIndex].id,
            polishPrompt: "Be terse.",
            polishOutputLanguage: "French",
            languageIdentifier: "en_GB",
            transcriptionRouting: .remoteBatch
        )
        let draft = DesktopProfileEditing.draft(for: shown, catalogue: catalogue)
        XCTAssertEqual(draft.id, shown.id)
        XCTAssertEqual(draft.name, "Shown")
        XCTAssertEqual(draft.executablePaths, [notepad])
        XCTAssertEqual(draft.transcription, .batch(index: batchIndex))
        XCTAssertEqual(draft.polishMode, .enabled)
        XCTAssertEqual(draft.polishModel, .index(polishIndex))
        XCTAssertEqual(draft.polishPrompt, "Be terse.")
        XCTAssertEqual(draft.polishOutputLanguage, "French")
        XCTAssertEqual(draft.language, .index(languageIndex))
        XCTAssertEqual(
            draft.notes, ["Also matches these macOS apps, which only the Mac editor changes: com.apple.Notes."]
        )

        let imported = DictationProfile(
            name: "Imported",
            matchers: [DictationProfileMatcher(kind: .urlPattern, value: "github.com")],
            transcriptionModelID: "local/whisperkit/tiny",
            polishEnabled: true,
            polishModelID: "local/post-processing/rules",
            languageIdentifier: "xx_YY",
            transcriptionRouting: .localBatch
        )
        let preserved = DesktopProfileEditing.draft(for: imported, catalogue: catalogue)
        XCTAssertEqual(preserved.transcription, .preserved)
        XCTAssertEqual(preserved.polishModel, .preserved)
        XCTAssertEqual(preserved.language, .preserved)
        XCTAssertTrue(preserved.executablePaths.isEmpty)
        XCTAssertEqual(preserved.notes.count, 4, preserved.notes.joined(separator: "\n"))
        XCTAssertTrue(preserved.notes.contains { $0.contains("WhisperKit Tiny") })
        XCTAssertTrue(preserved.notes.contains { $0.contains("xx_YY") })
        XCTAssertTrue(preserved.notes.contains { $0.contains("URL matcher") })
        XCTAssertFalse(preserved.notes.contains { $0.contains("selected live model") })
    }

    func testLiveOverrideReopensAsLive() throws {
        let profile = DictationProfile(
            name: "Live", transcriptionModelID: AssemblyAIModels.universal35ProStreamingID,
            transcriptionRouting: .remoteStreaming
        )
        let draft = DesktopProfileEditing.draft(for: profile, catalogue: catalogue)
        let index = try XCTUnwrap(catalogue.liveModels.firstIndex { $0.id == profile.transcriptionModelID })
        XCTAssertEqual(draft.transcription, .live(index: index))
        XCTAssertEqual(DesktopProfileEditing.profile(from: draft, original: profile, catalogue: catalogue), profile)
    }

    // MARK: - Profiles from drafts

    func testSavingAnUntouchedDraftReturnsTheStoredProfileByteForByte() throws {
        let stored = DictationProfile(
            id: UUID(),
            name: "Imported",
            matchers: [.bundleID("com.apple.mail"), .windowsExecutablePath(notepad),
            .bundleID("com.microsoft.Outlook")],
            transcriptionModelID: "local/whisperkit/tiny",
            polishEnabled: true,
            polishModelID: "local/post-processing/rules",
            polishPrompt: "Terse.",
            polishOutputLanguage: "German",
            polishIncludeLexiconDirectives: true,
            polishIncludeContextTags: false,
            languageIdentifier: "xx_YY",
            transcriptionRouting: .localBatch
        )
        let draft = DesktopProfileEditing.draft(for: stored, catalogue: catalogue)
        let saved = DesktopProfileEditing.profile(from: draft, original: stored, catalogue: catalogue)

        XCTAssertEqual(saved.id, stored.id)
        XCTAssertEqual(saved.matchers, [
            .bundleID("com.apple.mail"), .bundleID("com.microsoft.Outlook"), .windowsExecutablePath(notepad)
        ], "macOS matchers survive; Windows matchers are regrouped after them")
        XCTAssertEqual(saved.transcriptionModelID, "local/whisperkit/tiny")
        XCTAssertEqual(saved.transcriptionRouting, .localBatch)
        XCTAssertEqual(saved.polishModelID, "local/post-processing/rules")
        XCTAssertEqual(saved.polishPrompt, "Terse.")
        XCTAssertEqual(saved.polishOutputLanguage, "German")
        XCTAssertEqual(saved.polishIncludeLexiconDirectives, true)
        XCTAssertEqual(saved.polishIncludeContextTags, false)
        XCTAssertEqual(saved.languageIdentifier, "xx_YY")
        XCTAssertEqual(
            try DictationProfile.encodeList([saved]),
            try DictationProfile.encodeList([stored.replacingWindowsExecutablePaths([notepad])])
        )
    }

    func testChangingAPreservedChoiceReplacesItWithTheCatalogueValue() {
        let stored = DictationProfile(
            name: "Imported", transcriptionModelID: "local/whisperkit/tiny", polishEnabled: true,
            polishModelID: "local/post-processing/rules", languageIdentifier: "xx_YY", transcriptionRouting: .localBatch
        )
        var draft = DesktopProfileEditing.draft(for: stored, catalogue: catalogue)
        draft.transcription = .live(index: 0)
        draft.polishModel = .index(polishIndex)
        draft.language = .appSetting

        let saved = DesktopProfileEditing.profile(from: draft, original: stored, catalogue: catalogue)
        XCTAssertEqual(saved.transcriptionModelID, catalogue.liveModels[0].id)
        XCTAssertEqual(saved.transcriptionRouting, .remoteStreaming)
        XCTAssertEqual(saved.polishModelID, catalogue.polishModels[polishIndex].id)
        XCTAssertNil(saved.languageIdentifier)
        XCTAssertTrue(DictationProfileValidator.issues(for: saved).isEmpty)
    }

    func testPolishOptionsSurviveDisabledAndInheritedMode() {
        var draft = DesktopProfileEditing.Draft(name: " Notes ", executablePaths: [" \(notepad) ", "",
            notepad.uppercased()])
        draft.transcription = .batch(index: batchIndex)
        draft.polishMode = .enabled
        draft.polishModel = .index(polishIndex)
        draft.polishPrompt = " Rewrite as bullets. "
        draft.polishOutputLanguage = " British English "
        draft.language = .index(languageIndex)

        let created = DesktopProfileEditing.profile(from: draft, original: nil, catalogue: catalogue)
        XCTAssertEqual(created.name, "Notes")
        XCTAssertEqual(created.matchers, [.windowsExecutablePath(notepad)], "Blank and duplicate paths are dropped")
        XCTAssertEqual(created.transcriptionModelID, catalogue.batchModels[batchIndex].id)
        XCTAssertEqual(created.transcriptionRouting, .remoteBatch)
        XCTAssertEqual(created.polishEnabled, true)
        XCTAssertEqual(created.polishModelID, catalogue.polishModels[polishIndex].id)
        XCTAssertEqual(created.polishPrompt, "Rewrite as bullets.")
        XCTAssertEqual(created.polishOutputLanguage, "British English")
        XCTAssertNil(created.polishIncludeLexiconDirectives)
        XCTAssertEqual(created.languageIdentifier, "en_GB")
        XCTAssertTrue(DictationProfileValidator.issues(for: created).isEmpty)

        for mode in [DesktopProfileEditing.PolishMode.appSetting, .disabled] {
            draft.polishMode = mode
            let plain = DesktopProfileEditing.profile(from: draft, original: nil, catalogue: catalogue)
            XCTAssertEqual(plain.polishEnabled, mode == .disabled ? false : nil)
            XCTAssertEqual(plain.polishModelID, created.polishModelID)
            XCTAssertEqual(plain.polishPrompt, created.polishPrompt)
            XCTAssertEqual(plain.polishOutputLanguage, created.polishOutputLanguage)
        }
        XCTAssertNotEqual(
            DesktopProfileEditing.profile(from: draft, original: nil, catalogue: catalogue).id,
            DesktopProfileEditing.profile(from: draft, original: nil, catalogue: catalogue).id,
            "Each new profile receives its own identifier"
        )
    }

    // MARK: - Validation

    func testEditorIssuesCoverNameAndPathButNotPreservedValues() {
        var draft = DesktopProfileEditing.Draft(name: "  ", executablePaths: ["notepad.exe"])
        draft.transcription = .preserved
        draft.polishModel = .preserved
        XCTAssertEqual(DesktopProfileEditing.issues(for: draft, catalogue: catalogue), [
            .emptyName, .invalidWindowsExecutablePath(path: "notepad.exe")
        ])
        draft.name = "Fixed"
        draft.executablePaths = [notepad, #"\\server\share\App.exe"#]
        XCTAssertEqual(DesktopProfileEditing.issues(for: draft, catalogue: catalogue), [])
        XCTAssertEqual(
            DesktopProfileEditing.issues(for: DesktopProfileEditing.Draft(name: "No app"), catalogue: catalogue), []
        )
    }

    // MARK: - Merging a whole editing session

    func testMergeKeepsIdentifiersAppliesOrderAddsAndRemoves() throws {
        let first = DictationProfile(name: "First", matchers: [.windowsExecutablePath(notepad), .bundleID("a.b.c")])
        let second = DictationProfile(name: "Second", matchers: [.windowsExecutablePath(code)])
        let third = DictationProfile(name: "Third")
        var editedSecond = DesktopProfileEditing.draft(for: second, catalogue: catalogue)
        editedSecond.name = "Second renamed"
        let added = DesktopProfileEditing.Draft(name: "Added", executablePaths: [#"D:\Tools\tool.exe"#])

        let merged = try DesktopProfileEditing.merge(
            [editedSecond, added, DesktopProfileEditing.draft(for: first, catalogue: catalogue)],
            into: [first, second, third], catalogue: catalogue
        ).get()

        XCTAssertEqual(merged.map(\.name), ["Second renamed", "Added", "First"])
        XCTAssertEqual(merged[0].id, second.id)
        XCTAssertEqual(merged[2].id, first.id)
        XCTAssertEqual(merged[2].matchers, [.bundleID("a.b.c"), .windowsExecutablePath(notepad)])
        XCTAssertFalse(merged.contains { $0.id == third.id }, "A profile absent from the rows is removed")
        XCTAssertEqual(merged[1].windowsExecutablePaths, [#"D:\Tools\tool.exe"#])
    }

    func testMergeRejectsNewIssuesButToleratesPreExistingImportedOnes() {
        let imported = DictationProfile(
            name: "Imported", transcriptionModelID: "acme/fast-streaming", transcriptionRouting: .remoteStreaming
        )
        XCTAssertFalse(DictationProfileValidator.issues(for: imported).isEmpty)
        var renamed = DesktopProfileEditing.draft(for: imported, catalogue: catalogue)
        renamed.name = "Imported, renamed"
        let tolerated = DesktopProfileEditing.merge([renamed], into: [imported], catalogue: catalogue)
        XCTAssertEqual(try tolerated.get().map(\.name), ["Imported, renamed"])
        XCTAssertEqual(try tolerated.get()[0].transcriptionModelID, "acme/fast-streaming")

        var broken = renamed
        broken.executablePaths = ["relative.exe"]
        let rejected = DesktopProfileEditing.merge([broken], into: [imported], catalogue: catalogue)
        guard case .failure(let failure) = rejected else { return XCTFail("Expected a rejected merge") }
        XCTAssertEqual(failure.rejections.map(\.name), ["Imported, renamed"])
        XCTAssertEqual(failure.rejections[0].issues, [.invalidWindowsExecutablePath(path: "relative.exe")])
        XCTAssertTrue(failure.message.contains("relative.exe"))

        let unnamed = DesktopProfileEditing.merge([DesktopProfileEditing.Draft(name: " ")], into: [],
            catalogue: catalogue)
        guard case .failure(let unnamedFailure) = unnamed else { return XCTFail("Expected an empty-name rejection") }
        XCTAssertEqual(unnamedFailure.rejections[0].issues, [.emptyName])
        XCTAssertTrue(unnamedFailure.message.hasPrefix("Unnamed profile"))
    }

    func testNonblankDevicePrefixIsRejectedInsteadOfErasingItsMatcher() {
        let invalid = #"\\?\"#
        let draft = DesktopProfileEditing.Draft(name: "Incomplete path", executablePaths: [invalid])
        guard case .failure(let failure) = DesktopProfileEditing.merge([draft], into: [], catalogue: catalogue) else {
            return XCTFail("A nonblank incomplete path must be rejected")
        }
        XCTAssertEqual(failure.rejections.first?.issues, [.invalidWindowsExecutablePath(path: invalid)])
        XCTAssertEqual(DesktopProfileEditing.cleanedPaths(["", " \t", invalid, invalid]), [invalid])
        let blank = DesktopProfileEditing.Draft(name: "No Windows matcher", executablePaths: ["", " \t"])
        let saved = try? DesktopProfileEditing.merge([blank], into: [], catalogue: catalogue).get()
        XCTAssertEqual(saved?.first?.windowsExecutablePaths, [])
    }

    func testInvalidCatalogueSelectionsCannotSilentlyBecomeAppDefaults() {
        var draft = DesktopProfileEditing.Draft(name: "Invalid selections")
        for choice in [DesktopProfileEditing.TranscriptionChoice.batch(index: -1), .live(index: Int.max)] {
            draft.transcription = choice
            draft.polishModel = .index(Int.max)
            draft.language = .index(-1)
            let expected: [DictationProfileIssue] = [
                .invalidSelection(field: "a transcription model"), .invalidSelection(field: "a polish model"),
                .invalidSelection(field: "a spoken language")
            ]
            XCTAssertEqual(DesktopProfileEditing.issues(for: draft, catalogue: catalogue), expected)
            guard case .failure(let failure) = DesktopProfileEditing.merge([draft], into: [], catalogue: catalogue)
            else { return XCTFail("Invalid selections must block every save path") }
            XCTAssertEqual(failure.rejections.first?.issues, expected)
        }
    }

    func testDuplicateIdentifiersRejectEntireSaveInsteadOfDroppingAProfile() {
        let original = DictationProfile(name: "Original")
        let draft = DesktopProfileEditing.draft(for: original, catalogue: catalogue)
        guard case .failure(let failure) = DesktopProfileEditing.merge(
            [draft, draft], into: [original], catalogue: catalogue
        ) else { return XCTFail("Duplicate identifiers must not silently discard edits") }
        XCTAssertEqual(failure.rejections.first?.issues, [.duplicateProfile])
    }

    func testDisabledAndInheritedImportedProfilesKeepEveryPolishOption() {
        for enabled: Bool? in [false, nil] {
            let stored = DictationProfile(
                name: "Imported", polishEnabled: enabled, polishModelID: "local/post-processing/rules",
                polishPrompt: "Keep this prompt.", polishOutputLanguage: "French",
                polishIncludeLexiconDirectives: true, polishIncludeContextTags: false
            )
            let draft = DesktopProfileEditing.draft(for: stored, catalogue: catalogue)
            XCTAssertEqual(DesktopProfileEditing.profile(from: draft, original: stored, catalogue: catalogue), stored)
        }
    }
}
