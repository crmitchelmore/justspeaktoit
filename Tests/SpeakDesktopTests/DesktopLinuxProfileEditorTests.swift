import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopLinuxProfileEditorTests: XCTestCase {
    private let catalogue = DesktopProfileEditing.Catalogue(capabilities: .shared)

    private func fields(_ name: String = "Code") -> [String] {
        [name, "/usr/bin/Code", "batch:" + ModelCatalog.defaultBatchTranscriptionModel, "1",
         LocalPostProcessingModel.builtInRulesModelID, "Preserved prompt\twith %", "French", "", "0", "1"]
    }

    func testCanonicalChoicesAndContextOverridesRoundTripWithoutChangingOtherPlatformMatchers() throws {
        let original = DictationProfile(
            name: "Before", matchers: [.bundleID("com.apple.mail"), .windowsExecutablePath(#"C:\Apps\Mail.exe"#)]
        )
        let profile = try DesktopLinuxProfileEditor.edit(fields(), original: original, catalogue: catalogue)
        XCTAssertEqual(profile.id, original.id)
        XCTAssertEqual(profile.matchers.filter { $0.kind != .linuxExecutablePath }, original.matchers)
        XCTAssertEqual(profile.linuxExecutablePaths, ["/usr/bin/Code"])
        XCTAssertEqual(profile.transcriptionRouting, .remoteBatch)
        XCTAssertEqual(profile.polishModelID, LocalPostProcessingModel.builtInRulesModelID)
        XCTAssertEqual(profile.polishIncludeLexiconDirectives, false)
        XCTAssertEqual(profile.polishIncludeContextTags, true)
        let wire = DesktopLinuxProfileEditor.presentation(
            profiles: [profile], catalogue: catalogue, token: UUID(), active: profile.id, notice: "Saved"
        )
        let row = try XCTUnwrap(wire.components(separatedBy: "\n").first { $0.hasPrefix("R\t") })
        let decoded = try DesktopLinuxProfileEditor.fields(row)
        XCTAssertEqual(decoded[1], original.id.uuidString)
        XCTAssertEqual(decoded[7], profile.polishPrompt)
        XCTAssertTrue(wire.contains(DesktopLinuxProfileEditor.escape(DesktopPostProcessing.localRulesNotice)))
        XCTAssertEqual(try DesktopLinuxProfileEditor.edit(Array(decoded[2...11]), original: profile,
                                                         catalogue: catalogue), profile)
        var inherited = fields()
        inherited[8] = ""
        inherited[9] = ""
        let defaults = try DesktopLinuxProfileEditor.edit(inherited, original: profile, catalogue: catalogue)
        XCTAssertNil(defaults.polishIncludeLexiconDirectives)
        XCTAssertNil(defaults.polishIncludeContextTags)
    }

    func testLinuxMatcherUsesOnlyExactCapturedExecutableAndUserOrder() {
        let first = DictationProfile(name: "First", matchers: [
            .init(kind: .linuxExecutablePath, value: "/usr/bin/Code"), .bundleID("org.editor")
        ])
        let second = DictationProfile(name: "Second", matchers: [
            .init(kind: .linuxExecutablePath, value: "/usr/bin/Code")
        ])
        let resolver = ProfileResolver(profiles: [first, second])
        XCTAssertEqual(resolver.profile(forLinuxExecutablePath: "/usr/bin/Code")?.id, first.id)
        XCTAssertNil(resolver.profile(forLinuxExecutablePath: "/usr/bin/code"))
        XCTAssertNil(resolver.profile(forLinuxExecutablePath: "Code"))
        XCTAssertNil(resolver.profile(forLinuxExecutablePath: "org.editor"))
        XCTAssertNil(resolver.profile(forLinuxExecutablePath: nil), "Wayland supplies no captured executable.")
        XCTAssertNil(resolver.profile(forWindowsExecutablePath: "/usr/bin/Code"))
        XCTAssertEqual(ProfileResolver(profiles: [second, first])
            .profile(forLinuxExecutablePath: "/usr/bin/Code")?.id, second.id)
    }

    func testUnavailableLocalChoicesArePreservedAndNeverTurnedIntoRemoteFallback() throws {
        let profile = DictationProfile(
            name: "Imported", transcriptionModelID: "local/not-installed",
            polishEnabled: true, polishModelID: "local/future-llm", languageIdentifier: "future-language",
            transcriptionRouting: .localBatch
        )
        let wire = DesktopLinuxProfileEditor.presentation(
            profiles: [profile], catalogue: catalogue, token: UUID(), active: nil, notice: ""
        )
        let row = try XCTUnwrap(wire.components(separatedBy: "\n").first { $0.hasPrefix("R\t") })
        let decoded = try DesktopLinuxProfileEditor.fields(row)
        let edited = try DesktopLinuxProfileEditor.edit(Array(decoded[2...11]), original: profile, catalogue: catalogue)
        XCTAssertEqual(edited, profile)
        let session = DesktopProfileSessionResolver.resolve(
            profile: edited, defaultModel: ModelCatalog.defaultBatchTranscriptionModel,
            defaultPostProcessing: .init(), capabilities: catalogue.capabilities
        )
        XCTAssertFalse(session.canRecord)
        XCTAssertEqual(session.postProcessing.mode, .disabled)
        var future = DictationProfile(
            name: "Future", matchers: [.init(kind: .linuxExecutablePath, value: "not-an-executable-path")]
        )
        future.unsupportedTranscriptionRouting = "future-route-without-model"
        let futureWire = DesktopLinuxProfileEditor.presentation(
            profiles: [future], catalogue: catalogue, token: UUID(), active: nil, notice: ""
        )
        let futureRow = try XCTUnwrap(futureWire.components(separatedBy: "\n").first { $0.hasPrefix("R\t") })
        let futureFields = try DesktopLinuxProfileEditor.fields(futureRow)
        XCTAssertEqual(futureFields[4], "!")
        XCTAssertTrue(futureFields[12].contains("cannot match an app"))
        XCTAssertEqual(
            try DesktopLinuxProfileEditor.edit(Array(futureFields[2...11]), original: future, catalogue: catalogue),
            future
        )
    }

    func testInvalidPathsAndSelectionsAreRejectedRatherThanChangingProvider() {
        var values = fields()
        values[1] = "Code"
        XCTAssertThrowsError(try DesktopLinuxProfileEditor.edit(values, original: nil, catalogue: catalogue))
        values = fields()
        values[2] = "local:not-a-catalogue-model"
        XCTAssertThrowsError(try DesktopLinuxProfileEditor.edit(values, original: nil, catalogue: catalogue))
        XCTAssertThrowsError(try DesktopLinuxProfileEditor.fields("broken%ZZ"))
        XCTAssertThrowsError(try DesktopLinuxProfileEditor.edit([], original: nil, catalogue: catalogue))
    }
}
