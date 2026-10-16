import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostProfileEditorTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gtk-profiles-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let provider = try XCTUnwrap(DesktopHostModels.provider(for: ModelCatalog.defaultBatchTranscriptionModel))
        FakeLog.shared.setKey("synthetic-key", name: provider.apiKeyIdentifier)
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
        FakeLog.shared.reset()
    }

    private func token(_ wire: String) throws -> String {
        let header = try XCTUnwrap(wire.components(separatedBy: "\n").first)
        return try DesktopLinuxProfileEditor.fields(header)[1]
    }

    private func event(_ token: String, _ action: String, _ id: UUID?, fields: [String] = []) -> String {
        ([token, action, id?.uuidString ?? ""] + fields).map(DesktopLinuxProfileEditor.escape).joined(separator: "\t")
    }

    private func values(_ name: String) -> [String] {
        [name, "/usr/bin/Editor", "batch:" + ModelCatalog.defaultBatchTranscriptionModel, "1",
         LocalPostProcessingModel.builtInRulesModelID, "Keep this remote prompt", "French", "", "0", "1"]
    }

    private func selectedProfileID(_ wire: String) throws -> String {
        let header = try XCTUnwrap(wire.components(separatedBy: "\n").first)
        return try DesktopLinuxProfileEditor.fields(header)[2]
    }

    private func restartController(with profiles: [DictationProfile]? = nil) async throws {
        if let profiles { try DesktopDictationProfileStore(directory: directory).save(profiles) }
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
    }

    func testNativePayloadCRUDDuplicateOrderAndRestartUseCanonicalStore() async throws {
        let probe = LocalRulesCredentialProbe()
        FakeLog.shared.installKeyReadHook { _ in probe.read() }
        FakeLog.shared.installKeyWriteHook { _, _ in probe.write() }
        let opened = try await controller.profileEditorEvent("refresh")
        let created = try await controller.profileEditorEvent(event(token(opened), "save", nil, fields: values("First")))
        let savedProfiles = await controller.profiles
        let original = try XCTUnwrap(savedProfiles.first)
        let duplicated = try await controller.profileEditorEvent(event(token(created), "duplicate", original.id))
        let two = await controller.profiles
        XCTAssertEqual(two.count, 2)
        XCTAssertNotEqual(two[0].id, two[1].id)
        let reordered = try await controller.profileEditorEvent(event(token(duplicated), "up", two[1].id))
        let ordered = await controller.profiles
        XCTAssertEqual(ordered.map(\.id), [two[1].id, two[0].id])
        let renamed = try await controller.profileEditorEvent(
            event(token(reordered), "save", original.id, fields: values("Renamed"))
        )
        _ = try await controller.profileEditorEvent(event(token(renamed), "delete", two[1].id))
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: SyntheticEffects())
        let restored = await controller.profiles
        XCTAssertEqual(restored.map(\.name), ["Renamed"])
        XCTAssertEqual(restored.first?.id, original.id)
        XCTAssertEqual(restored.first?.polishIncludeLexiconDirectives, false)
        XCTAssertEqual(restored.first?.polishIncludeContextTags, true)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.writes, 0)
    }

    func testCapturedManualSelectionOwnsActualNextRecordingDespiteLaterSelection() async throws {
        let store = DesktopDictationProfileStore(directory: directory)
        let first = DictationProfile(
            name: "First", polishEnabled: true, polishModelID: LocalPostProcessingModel.builtInRulesModelID,
            languageIdentifier: "fr_FR"
        )
        let second = DictationProfile(name: "Second", polishEnabled: false)
        try store.save([first, second])
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let opened = try await controller.profileEditorEvent("refresh")
        let activated = try await controller.profileEditorEvent(event(token(opened), "activate", first.id))
        let index = await controller.selectedIndex()
        let captured = await controller.captureProfile(modelIndex: index, executablePath: nil)
        _ = try await controller.profileEditorEvent(event(token(activated), "activate", second.id))
        XCTAssertEqual(captured.profileName, "First")
        XCTAssertEqual(captured.language, TranscriptionLanguageCatalog.providerLanguage(for: "fr_FR"))
        XCTAssertNotNil(captured.language)
        XCTAssertEqual(captured.postProcessing.mode, .local)
        await controller.toggleCaptured(
            target: nil, modelIndex: index, deviceID: "", textOutput: .init(), profile: captured
        )
        let recordingProfile = await controller.recording?.profile
        let recordingName = await controller.recording?.record.profileName
        let recordingLanguage = await controller.recording?.record.languageIdentifier
        XCTAssertEqual(recordingProfile, captured)
        XCTAssertEqual(recordingName, first.name)
        XCTAssertEqual(recordingLanguage, captured.language)
        XCTAssertEqual(recordingProfile?.postProcessing.modelIdentifier, LocalPostProcessingModel.builtInRulesModelID)
    }

    func testCapturedAndResolvedManualProfilesRetainOptionsAfterSettingsChange() async throws {
        let manual = DictationProfile(name: "Manual")
        try await restartController(with: [manual])
        var entries = try await controller.configuration().entries
        let wordsIndex = try XCTUnwrap(DesktopConfiguration.fields.firstIndex {
            $0.key == "transcriptionKeywords"
        })
        entries[wordsIndex] = "CapturedTerm"
        try await controller.saveConfiguration(entries)
        let expected = try await controller.configuration().liveOptions
        let opened = try await controller.profileEditorEvent("refresh")
        _ = try await controller.profileEditorEvent(event(token(opened), "activate", manual.id))
        let captured = await controller.captureProfile(modelIndex: nil, executablePath: nil)
        let resolved = await controller.resolvedProfile(executablePath: nil)
        XCTAssertEqual(captured.profileName, manual.name)
        XCTAssertEqual(resolved.profileName, manual.name)
        XCTAssertEqual(captured.transcriptionOptions, expected)
        XCTAssertEqual(resolved.transcriptionOptions, expected)
        XCTAssertEqual(captured.transcriptionKeywords, ["CapturedTerm"])
        entries = try await controller.configuration().entries
        entries[wordsIndex] = "ChangedTerm"
        try await controller.saveConfiguration(entries)
        let next = await controller.captureProfile(modelIndex: nil, executablePath: nil)
        XCTAssertEqual(next.transcriptionKeywords, ["ChangedTerm"])
        XCTAssertEqual(captured.transcriptionKeywords, ["CapturedTerm"])
        XCTAssertEqual(resolved.transcriptionKeywords, ["CapturedTerm"])
    }

    func testStaleRevisionAndUnknownIDCannotMutateSavedProfiles() async throws {
        let opened = try await controller.profileEditorEvent("refresh")
        _ = try await controller.profileEditorEvent(event(token(opened), "save", nil, fields: values("First")))
        let before = try DesktopDictationProfileStore(directory: directory).rawDocument()
        do {
            _ = try await controller.profileEditorEvent(event(token(opened), "delete", UUID()))
            XCTFail("Stale revision accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Reopen Profiles"))
        }
        XCTAssertEqual(try DesktopDictationProfileStore(directory: directory).rawDocument(), before)
        let refreshed = try await controller.profileEditorEvent("refresh")
        do {
            _ = try await controller.profileEditorEvent(event(token(refreshed), "delete", UUID()))
            XCTFail("Unknown profile accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Choose a saved profile"))
        }
        XCTAssertEqual(try DesktopDictationProfileStore(directory: directory).rawDocument(), before)
    }

    func testDeletedManualProfileDoesNotRematchUntilExplicitAutomaticAndRestartClearsSelection() async throws {
        let path = #"C:\Apps\Editor.exe"#
        let manual = DictationProfile(name: "Manual", polishEnabled: false)
        let alternate = DictationProfile(
            name: "Automatic", matchers: [
                .windowsExecutablePath(path), .init(kind: .linuxExecutablePath, value: "/usr/bin/Editor")
            ], transcriptionModelID: ModelCatalog.defaultBatchTranscriptionModel,
            polishEnabled: true, polishModelID: LocalPostProcessingModel.builtInRulesModelID,
            languageIdentifier: "fr_FR", transcriptionRouting: .remoteBatch
        )
        try await restartController(with: [manual, alternate])
        let index = await controller.selectedIndex()
        let automatic = await controller.captureProfile(modelIndex: index, executablePath: path)
        XCTAssertEqual(automatic.profileName, alternate.name)
        XCTAssertEqual(automatic.postProcessing.mode, .local)
        XCTAssertEqual(FakePlatform.matchProfile([alternate], executablePath: path)?.id, alternate.id)
        XCTAssertEqual(
            ProfileResolver(profiles: [alternate]).profile(forLinuxExecutablePath: "/usr/bin/Editor")?.id,
            alternate.id
        )
        let opened = try await controller.profileEditorEvent("refresh")
        let activated = try await controller.profileEditorEvent(event(token(opened), "activate", manual.id))
        let admitted = await controller.captureProfile(modelIndex: index, executablePath: path)
        XCTAssertEqual(admitted.profileName, manual.name)
        let deleted = try await controller.profileEditorEvent(event(token(activated), "delete", manual.id))
        XCTAssertEqual(try selectedProfileID(deleted), manual.id.uuidString)
        let next = await controller.captureProfile(modelIndex: index, executablePath: path)
        let defaults = await controller.captureProfile(modelIndex: index, executablePath: nil)
        XCTAssertNil(next.profileName)
        XCTAssertEqual(next, defaults)
        XCTAssertEqual(next.postProcessing.mode, .disabled)
        let refreshed = try await controller.profileEditorEvent("refresh")
        XCTAssertEqual(try selectedProfileID(refreshed), manual.id.uuidString)
        let explicit = try await controller.profileEditorEvent(event(token(refreshed), "activate", nil))
        let afterExplicitAutomatic = await controller.captureProfile(modelIndex: index, executablePath: path)
        XCTAssertEqual(afterExplicitAutomatic, automatic)
        XCTAssertEqual(admitted.profileName, manual.name)
        _ = try await controller.profileEditorEvent(event(token(explicit), "activate", alternate.id))
        try await restartController()
        let restartedSelection = await controller.manualProfileID
        let restarted = await controller.captureProfile(modelIndex: index, executablePath: path)
        XCTAssertNil(restartedSelection)
        XCTAssertEqual(restarted, automatic)
    }
}
