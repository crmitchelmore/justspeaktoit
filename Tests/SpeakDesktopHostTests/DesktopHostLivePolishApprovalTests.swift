import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopHostLivePolishApprovalTests: XCTestCase {
    func testImportedUnapprovedMode_BothSoundPreviewsPersistAndPlayWithoutGrantingApproval() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        try await importUnapproved(fixture)
        let output = ApprovalPreviewOutput()
        await fixture.host.prepareRecordingFeedback(loader: ApprovalPreviewLoader(output: output))
        for sound in [RecordingFeedbackSound.start, .stop] {
            let entries = try await editedEntries(fixture, changes: [
                "recordingSoundVolume": AnyCodable(.double(0.25)),
                "recordingSoundProfile": AnyCodable(.string("bubbly"))
            ])
            try await preview(fixture, sound: sound, entries: entries)
            try assertPersistedApproval(fixture, expected: false)
            await assertUnapprovedAdmission(fixture)
        }
        XCTAssertEqual(output.sounds, [.start, .stop])
        XCTAssertEqual(output.gains.count, 2)
        XCTAssertTrue(output.gains.allSatisfy { abs($0 - RecordingFeedbackDefaults.gain(for: 0.25)) < 0.000_001 })
        let saved = try await fixture.host.configuration()
        XCTAssertEqual(saved.number("recordingSoundVolume"), 0.25)
        XCTAssertEqual(saved.text("recordingSoundProfile"), "bubbly")
        XCTAssertTrue(fixture.effects.keyReads.isEmpty)
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
    }

    func testStagedAutoCleanInInstantForm_PreviewNeverGrantsPermissionOrReadsCleanupKey() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(enabled: false)
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.host.prepareRecordingFeedback(loader: ApprovalPreviewLoader(output: ApprovalPreviewOutput()))
        let staged = try await editedEntries(fixture, changes: ["speedMode": AnyCodable(.string("livePolish"))])
        try await preview(fixture, sound: .start, entries: staged)
        try assertPersistedApproval(fixture, expected: false)
        await assertUnapprovedAdmission(fixture)
        XCTAssertTrue(fixture.effects.keyReads.isEmpty)
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
    }

    func testApprovedUnchangedSelection_BothPreviewsKeepApprovalAndSoundSettings() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let output = ApprovalPreviewOutput()
        await fixture.host.prepareRecordingFeedback(loader: ApprovalPreviewLoader(output: output))
        for sound in [RecordingFeedbackSound.start, .stop] {
            let entries = try await editedEntries(fixture, changes: [
                "recordingSoundVolume": AnyCodable(.double(0.4)),
                "recordingSoundProfile": AnyCodable(.string("soft"))
            ])
            try await preview(fixture, sound: sound, entries: entries)
            try assertPersistedApproval(fixture, expected: true)
        }
        XCTAssertEqual(output.sounds, [.start, .stop])
        XCTAssertTrue(fixture.effects.keyReads.isEmpty, "Persistence/preview itself never resolves a cleanup key")
        let profile = await fixture.host.captureProfile(modelIndex: fixture.modelIndex, executablePath: nil)
        let captured = await fixture.host.captureLivePolish(profile)
        XCTAssertNil(captured?.failure)
        XCTAssertEqual(captured?.model, ModelCatalog.defaultFastTextModel)
        XCTAssertEqual(fixture.effects.keyReads, ["openrouter.apiKey"])
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
    }

    func testChangedAutoCleanSelection_PreviewRevokesApprovalAndCannotRegrantItOnSecondPreview() async throws {
        let alternate = try XCTUnwrap(DesktopPostProcessing.remoteModels.first {
            $0.id != ModelCatalog.defaultFastTextModel
        }).id
        let changes: [[String: AnyCodable]] = [
            ["livePolishModel": AnyCodable(.string(alternate))],
            ["livePolishDebounceMs": AnyCodable(.int(250))],
            ["livePolishMinDeltaChars": AnyCodable(.int(7))],
            ["skipPostProcessingWithLivePolish": AnyCodable(.bool(false))]
        ]
        for change in changes {
            let fixture = AutoCleanHostFixture()
            try await fixture.prepare()
            await fixture.host.prepareRecordingFeedback(loader: ApprovalPreviewLoader(output: ApprovalPreviewOutput()))
            let entries = try await editedEntries(fixture, changes: change)
            for sound in [RecordingFeedbackSound.start, .stop] {
                try await preview(fixture, sound: sound, entries: entries)
                try assertPersistedApproval(fixture, expected: false)
                await assertUnapprovedAdmission(fixture)
            }
            let saved = try await fixture.host.configuration()
            for (key, value) in change {
                switch value.storage {
                case .int(let number): XCTAssertEqual(saved.number(key), Double(number))
                case .bool(let flag): XCTAssertEqual(saved.enabled(key), flag)
                case .string(let text): XCTAssertEqual(saved.text(key), text)
                default: XCTFail("Unexpected approval fixture value")
                }
            }
            XCTAssertTrue(fixture.effects.keyReads.isEmpty)
            XCTAssertTrue(fixture.effects.cleanups.isEmpty)
            try await fixture.cleanup()
        }
    }

    func testPreviewSwitchToInstant_RevokesApprovalAndRetainsNoCleanupAdmission() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.host.prepareRecordingFeedback(loader: ApprovalPreviewLoader(output: ApprovalPreviewOutput()))
        let entries = try await editedEntries(fixture, changes: ["speedMode": AnyCodable(.string("instant"))])
        try await preview(fixture, sound: .stop, entries: entries)
        try assertPersistedApproval(fixture, expected: false)
        let profile = await fixture.host.captureProfile(modelIndex: fixture.modelIndex, executablePath: nil)
        let captured = await fixture.host.captureLivePolish(profile)
        XCTAssertNil(captured)
        XCTAssertTrue(fixture.effects.keyReads.isEmpty)
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
    }

    func testExplicitApply_AuthorizesImportedModeOnlyAfterPreviewLeftItUnapproved() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        try await importUnapproved(fixture)
        await fixture.host.prepareRecordingFeedback(loader: ApprovalPreviewLoader(output: ApprovalPreviewOutput()))
        let entries = try await fixture.host.configurationForNativeEditor().entries
        try await preview(fixture, sound: .start, entries: entries)
        try assertPersistedApproval(fixture, expected: false)
        try await fixture.host.saveConfiguration(entries, intent: .apply)
        try assertPersistedApproval(fixture, expected: true)
        XCTAssertTrue(fixture.effects.keyReads.isEmpty)
        let profile = await fixture.host.captureProfile(modelIndex: fixture.modelIndex, executablePath: nil)
        let captured = await fixture.host.captureLivePolish(profile)
        XCTAssertNil(captured?.failure)
        XCTAssertEqual(fixture.effects.keyReads, ["openrouter.apiKey"])
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
    }

    func testChangedFallbackModel_RevokesOnlyWhenAutoCleanActuallyUsesThatFallback() async throws {
        let alternate = try XCTUnwrap(DesktopPostProcessing.remoteModels.first {
            $0.id != ModelCatalog.defaultFastTextModel && $0.id != DesktopPostProcessing.Options().modelIdentifier
        }).id
        for explicit in [false, true] {
            let fixture = AutoCleanHostFixture()
            try await fixture.prepare()
            let entries = try await editedEntries(fixture, changes: [
                "livePolishModel": AnyCodable(.string(explicit ? ModelCatalog.defaultFastTextModel : ""))
            ])
            try await fixture.host.saveConfiguration(entries, intent: .apply)
            await fixture.host.savePostProcessing(
                enabled: false, modelIdentifier: alternate, prompt: "", key: ""
            )
            let options = await fixture.host.postProcessingOptions()
            XCTAssertEqual(options.modelIdentifier, alternate)
            try assertPersistedApproval(fixture, expected: explicit)
            await fixture.host.prepareRecordingFeedback(loader: ApprovalPreviewLoader(output: ApprovalPreviewOutput()))
            let updated = try await fixture.host.configurationForNativeEditor().entries
            try await preview(fixture, sound: .stop, entries: updated)
            try assertPersistedApproval(fixture, expected: explicit)
            XCTAssertTrue(fixture.effects.keyReads.isEmpty)
            XCTAssertTrue(fixture.effects.cleanups.isEmpty)
            try await fixture.cleanup()
        }
    }

    func testEquivalentModelWhitespaceAndUnrelatedFields_PreviewPreservesApproval() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.host.prepareRecordingFeedback(loader: ApprovalPreviewLoader(output: ApprovalPreviewOutput()))
        let entries = try await editedEntries(fixture, changes: [
            "livePolishModel": AnyCodable(.string("  " + ModelCatalog.defaultFastTextModel + "  ")),
            "livePolishMinDeltaChars": AnyCodable(.double(20)),
            "postProcessingTemperature": AnyCodable(.double(0.75)),
            "postProcessingOutputLanguage": AnyCodable(.string("French"))
        ])
        try await preview(fixture, sound: .start, entries: entries)
        try assertPersistedApproval(fixture, expected: true)
        XCTAssertTrue(fixture.effects.keyReads.isEmpty)
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
    }

    private func importUnapproved(_ fixture: AutoCleanHostFixture) async throws {
        let configuration = try await fixture.host.configuration()
        let url = fixture.directory.appendingPathComponent("approval-import.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: configuration)).write(to: url)
        try await fixture.host.importConfiguration(path: url.path)
        try assertPersistedApproval(fixture, expected: false)
    }

    private func editedEntries(
        _ fixture: AutoCleanHostFixture, changes: [String: AnyCodable]
    ) async throws -> [String] {
        var values = try await fixture.host.configurationForNativeEditor().values
        values.merge(changes) { _, replacement in replacement }
        return try DesktopConfiguration(values: values).entries
    }

    private func preview(
        _ fixture: AutoCleanHostFixture, sound: RecordingFeedbackSound, entries: [String]
    ) async throws {
        try await fixture.host.previewRecordingFeedback(sound, configurationEntries: entries)
        let pending = await fixture.host.recordingFeedbackPreview
        await pending?.value
    }

    private func assertPersistedApproval(_ fixture: AutoCleanHostFixture, expected: Bool) throws {
        let data = try Data(contentsOf: fixture.directory.appendingPathComponent("settings.json"))
        let saved = try JSONDecoder().decode(DesktopHostController<FakePlatform>.Settings.self, from: data)
        XCTAssertEqual(saved.livePolishApproved, expected)
    }

    private func assertUnapprovedAdmission(_ fixture: AutoCleanHostFixture) async {
        let profile = await fixture.host.captureProfile(modelIndex: fixture.modelIndex, executablePath: nil)
        let captured = await fixture.host.captureLivePolish(profile)
        XCTAssertTrue(captured?.failure?.contains("not authorized") == true)
    }
}

private struct ApprovalPreviewLoader: DesktopRecordingFeedbackLoader {
    let output: ApprovalPreviewOutput
    func prepare(profile: RecordingFeedbackProfile) async throws -> any DesktopRecordingFeedbackOutput { output }
}

private final class ApprovalPreviewOutput: DesktopRecordingFeedbackOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var played: [RecordingFeedbackSound] = []
    private var levels: [Float] = []
    var sounds: [RecordingFeedbackSound] { lock.withLock { played } }
    var gains: [Float] { lock.withLock { levels } }
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {}
    func play(_ sound: RecordingFeedbackSound, gain: Float) throws {
        lock.withLock { played.append(sound); levels.append(gain) }
    }
    func stop() {}
    func close() async throws {}
}
