import Foundation
import XCTest
@testable import SpeakCore

/// The Windows executable-path matcher next to the macOS bundle-ID matcher:
/// exact full-path matching, format compatibility in both directions and the
/// rule that neither platform derives the other's identity.
final class DictationProfileWindowsMatcherTests: XCTestCase {
    private let notepadPath = #"C:\Windows\System32\notepad.exe"#
    private let codePath = #"C:\Users\Alex\AppData\Local\Programs\Microsoft VS Code\Code.exe"#

    private var codeProfile: DictationProfile {
        DictationProfile(
            name: "Code",
            matchers: [.bundleID("com.microsoft.VSCode"), .windowsExecutablePath(codePath)],
            polishEnabled: false
        )
    }

    private var notesProfile: DictationProfile {
        DictationProfile(name: "Notes", matchers: [.windowsExecutablePath(notepadPath)], polishEnabled: true)
    }

    // MARK: - Resolution

    func testExactFullPathMatches_CaseInsensitivelyWithNormalisedSeparators() {
        let resolver = ProfileResolver(profiles: [codeProfile, notesProfile])

        XCTAssertEqual(resolver.profile(forWindowsExecutablePath: notepadPath)?.name, "Notes")
        XCTAssertEqual(resolver.profile(forWindowsExecutablePath: #"c:\windows\system32\NOTEPAD.EXE"#)?.name, "Notes")
        XCTAssertEqual(resolver.profile(forWindowsExecutablePath: "C:/Windows/System32/notepad.exe")?.name, "Notes")
        XCTAssertEqual(resolver.profile(forWindowsExecutablePath: #"\\?\C:\Windows\System32\notepad.exe"#)?.name, "Notes")
        XCTAssertEqual(resolver.profile(forWindowsExecutablePath: "  \(codePath)\n")?.name, "Code")
    }

    func testBaseNamesRelativePathsAndOtherFilesNeverMatch() {
        let resolver = ProfileResolver(profiles: [notesProfile])

        XCTAssertNil(resolver.profile(forWindowsExecutablePath: "notepad.exe"))
        XCTAssertNil(resolver.profile(forWindowsExecutablePath: #"System32\notepad.exe"#))
        XCTAssertNil(resolver.profile(forWindowsExecutablePath: #"D:\Windows\System32\notepad.exe"#))
        XCTAssertNil(resolver.profile(forWindowsExecutablePath: #"C:\Windows\System32\notepad.exe.bak"#))
        XCTAssertNil(resolver.profile(forWindowsExecutablePath: #"C:\Windows\System32\"#))
    }

    func testNilAndBlankPathsAndBlankMatchersFallBackToDefaults() {
        let blank = DictationProfile(name: "Blank", matchers: [.windowsExecutablePath("   ")])
        let resolver = ProfileResolver(profiles: [blank, notesProfile])

        XCTAssertNil(resolver.profile(forWindowsExecutablePath: nil))
        XCTAssertNil(resolver.profile(forWindowsExecutablePath: ""))
        XCTAssertNil(resolver.profile(forWindowsExecutablePath: " \t "))
        XCTAssertEqual(resolver.profile(forWindowsExecutablePath: notepadPath)?.name, "Notes")
    }

    func testFirstProfileInUserOrderWins_AndUnmatchedPathsReturnNil() {
        let duplicate = DictationProfile(name: "Notes Override", matchers: [.windowsExecutablePath(notepadPath)])
        XCTAssertEqual(
            ProfileResolver(profiles: [notesProfile, duplicate])
                .profile(forWindowsExecutablePath: notepadPath)?.name, "Notes"
        )
        XCTAssertEqual(
            ProfileResolver(profiles: [duplicate, notesProfile])
                .profile(forWindowsExecutablePath: notepadPath)?.name, "Notes Override"
        )
        XCTAssertNil(ProfileResolver(profiles: [notesProfile]).profile(forWindowsExecutablePath: codePath))
    }

    func testPlatformsNeverGuessEachOthersIdentity() {
        let resolver = ProfileResolver(profiles: [codeProfile])

        XCTAssertNil(resolver.profile(forWindowsExecutablePath: "com.microsoft.VSCode"))
        XCTAssertNil(resolver.profile(forBundleID: codePath))
        XCTAssertNil(resolver.profile(forBundleID: "Code.exe"))
        XCTAssertEqual(resolver.profile(forBundleID: "com.microsoft.vscode")?.name, "Code")
        XCTAssertEqual(resolver.profile(forWindowsExecutablePath: codePath)?.name, "Code")
    }

    // MARK: - Normalisation and validation

    func testNormalisationFoldsCaseSeparatorsAndExtendedPrefixes() {
        XCTAssertEqual(
            DictationProfileMatcher.normalizedWindowsExecutablePath(#" \\?\C:\Apps\App.EXE "#), #"c:\apps\app.exe"#
        )
        XCTAssertEqual(
            DictationProfileMatcher.normalizedWindowsExecutablePath(#"\\?\UNC\server\share\App.exe"#),
            #"\\server\share\app.exe"#
        )
        XCTAssertEqual(DictationProfileMatcher.normalizedWindowsExecutablePath("C:/Apps/App.exe"), #"c:\apps\app.exe"#)
        XCTAssertNil(DictationProfileMatcher.normalizedWindowsExecutablePath(nil))
        XCTAssertNil(DictationProfileMatcher.normalizedWindowsExecutablePath("  "))
    }

    func testFullPathRuleAcceptsDriveAndUNCPathsOnly() {
        XCTAssertTrue(DictationProfileMatcher.isFullWindowsExecutablePath(notepadPath))
        XCTAssertTrue(DictationProfileMatcher.isFullWindowsExecutablePath(#"d:\App.exe"#))
        XCTAssertTrue(DictationProfileMatcher.isFullWindowsExecutablePath(#"\\server\share\App.exe"#))
        XCTAssertTrue(DictationProfileMatcher.isFullWindowsExecutablePath(#"\\?\C:\Apps\App.exe"#))
        for rejected in [
            "notepad.exe", #"System32\notepad.exe"#, #"C:\"#, #"C:notepad.exe"#, #"\\server\App.exe"#,
            #"\\server\\App.exe"#, #"C:\Apps\"#, "", "  ", "/usr/bin/vim"
        ] {
            XCTAssertFalse(DictationProfileMatcher.isFullWindowsExecutablePath(rejected), rejected)
        }
    }

    func testValidatorFlagsRelativeWindowsPaths_AndKeepsBlankMatchersInert() {
        let relative = DictationProfile(name: "Relative", matchers: [.windowsExecutablePath("notepad.exe")])
        XCTAssertEqual(
            DictationProfileValidator.issues(for: relative), [.invalidWindowsExecutablePath(path: "notepad.exe")]
        )
        XCTAssertFalse(DictationProfileIssue.invalidWindowsExecutablePath(path: "x").message.isEmpty)

        let blank = DictationProfile(name: "Blank", matchers: [.windowsExecutablePath(" ")])
        XCTAssertEqual(DictationProfileValidator.issues(for: blank), [])
        XCTAssertEqual(DictationProfileValidator.issues(for: notesProfile), [])
        XCTAssertEqual(
            DictationProfileValidator.issues(for: DictationProfile(name: "Mac", matchers: [.bundleID("x")])), []
        )
    }

    // MARK: - Serialisation

    func testWindowsMatchersRoundTripThroughTheCanonicalListEncoding() throws {
        let profiles = [codeProfile, notesProfile]
        let data = try DictationProfile.encodeList(profiles)
        let decoded = try DictationProfile.decodeList(data)

        XCTAssertEqual(decoded, profiles)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""kind":"windowsExecutablePath""#), json)
        XCTAssertTrue(json.contains(#""kind":"bundleID""#), json)
    }

    func testAppleProfileFormatDecodesUnchanged_AndUnknownKindsAreStillDropped() throws {
        let json = """
        [
          {
            "id": "6F1E32F9-31A5-4C1E-9E32-9E4CB25B7A4C",
            "name": "Email",
            "matchers": [
              {"kind": "bundleID", "value": "com.apple.mail"},
              {"kind": "windowTitle", "value": "Inbox"},
              {"kind": "windowsExecutablePath", "value": "C:\\\\Program Files\\\\Mail\\\\Mail.exe"}
            ],
            "polishEnabled": true,
            "polishOutputLanguage": "British English"
          }
        ]
        """
        let decoded = try DictationProfile.decodeList(Data(json.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].matchers, [
            .bundleID("com.apple.mail"), .windowsExecutablePath(#"C:\Program Files\Mail\Mail.exe"#)
        ])
        XCTAssertEqual(decoded[0].polishEnabled, true)
        XCTAssertEqual(decoded[0].polishOutputLanguage, "British English")
        XCTAssertEqual(decoded[0].windowsExecutablePaths, [#"C:\Program Files\Mail\Mail.exe"#])
        XCTAssertEqual(
            ProfileResolver(profiles: decoded).profile(forWindowsExecutablePath: #"c:\program files\mail\mail.exe"#)?.name,
            "Email"
        )
        XCTAssertEqual(ProfileResolver(profiles: decoded).profile(forBundleID: "COM.APPLE.MAIL")?.name, "Email")
    }

    func testReplacingWindowsPathsKeepsMacMatchersIdentityAndOverrides() {
        let original = DictationProfile(
            id: UUID(),
            name: "Code",
            matchers: [
                .bundleID("com.microsoft.VSCode"),
                .windowsExecutablePath(codePath),
                DictationProfileMatcher(kind: .urlPattern, value: "github.com"),
                .bundleID("com.apple.dt.Xcode")
            ],
            transcriptionModelID: "local/whisperkit/tiny",
            polishEnabled: true,
            transcriptionRouting: .localBatch
        )

        let replaced = original.replacingWindowsExecutablePaths([notepadPath, codePath])

        XCTAssertEqual(replaced.id, original.id)
        XCTAssertEqual(replaced.matchers, [
            .bundleID("com.microsoft.VSCode"),
            DictationProfileMatcher(kind: .urlPattern, value: "github.com"),
            .bundleID("com.apple.dt.Xcode"),
            .windowsExecutablePath(notepadPath),
            .windowsExecutablePath(codePath)
        ])
        XCTAssertEqual(replaced.transcriptionModelID, "local/whisperkit/tiny")
        XCTAssertEqual(replaced.transcriptionRouting, .localBatch)
        XCTAssertEqual(replaced.polishEnabled, true)
        XCTAssertEqual(original.replacingWindowsExecutablePaths([]).windowsExecutablePaths, [])
        XCTAssertEqual(
            original.replacingWindowsExecutablePaths([]).matchers.filter { $0.kind == .bundleID }.count, 2
        )
    }
}
