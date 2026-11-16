#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Downloaded `local/...` transcription models on iOS (issue #1650): routing,
/// readiness, no cloud fallback, silent audio and the Settings selection.
@MainActor
final class IOSDownloadedLocalModelTests: XCTestCase {
    private final class FakeEngine: IOSLocalTranscriptionEngine, @unchecked Sendable {
        var installed: Set<String> = []
        var transcript = ""
        private(set) var transcribedModels: [String] = []

        func isInstalled(_ model: LocalTranscriptionModel) -> Bool { installed.contains(model.id) }
        func installedSizeBytes(_ model: LocalTranscriptionModel) -> Int64? { nil }
        func isRecommendedOnThisDevice(_ model: LocalTranscriptionModel) -> Bool { true }
        func install(_ model: LocalTranscriptionModel, progress: @escaping @Sendable (Double) -> Void) async throws {
            installed.insert(model.id)
        }
        func remove(_ model: LocalTranscriptionModel) throws { installed.remove(model.id) }
        func transcribe(fileAt url: URL, model: LocalTranscriptionModel, language: String?) async throws -> String {
            transcribedModels.append(model.id)
            return transcript
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var engine: FakeEngine!
    private var previousEngine: IOSLocalTranscriptionEngine?
    private var model: LocalTranscriptionModel { ModelCatalog.iOSLocalTranscription[0] }
    private let audioURL = URL(fileURLWithPath: "/dev/null")

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "IOSDownloadedLocalModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        engine = FakeEngine()
        previousEngine = IOSLocalTranscriptionEngines.current
        IOSLocalTranscriptionEngines.register(engine)
    }

    override func tearDown() async throws {
        IOSLocalTranscriptionEngines.register(previousEngine)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        engine = nil
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, loadsSecureStorage: false)
    }

    // MARK: - Routing

    func testRoute_downloadedModelsRunLocallyAndAppleSpeechStaysApple() {
        for entry in ModelCatalog.iOSLocalTranscription {
            XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: entry.id), .downloadedLocal, entry.id)
        }
        XCTAssertNotEqual(
            IOSBatchTranscriptionRoute.route(for: ModelCatalog.defaultOnDeviceLiveTranscriptionModel),
            .downloadedLocal
        )
    }

    // MARK: - No cloud fallback

    func testTranscribe_withoutAnEngine_refusesInsteadOfUploading() async {
        await assertThrows(.engineUnavailable) {
            _ = try await IOSLocalTranscriptionModels.transcribe(
                at: self.audioURL, modelID: self.model.id, language: nil, engine: nil, imported: []
            )
        }
    }

    func testTranscribe_beforeDownload_refusesInsteadOfUploading() async {
        await assertThrows(.notDownloaded(model.displayName)) {
            _ = try await IOSLocalTranscriptionModels.transcribe(
                at: self.audioURL, modelID: self.model.id, language: nil, engine: self.engine, imported: []
            )
        }
        XCTAssertTrue(engine.transcribedModels.isEmpty)
    }

    func testTranscribe_unknownLocalModel_isRejected() async {
        await assertThrows(.unknownModel("local/whisperkit/not-a-model")) {
            _ = try await IOSLocalTranscriptionModels.transcribe(
                at: self.audioURL, modelID: "local/whisperkit/not-a-model", language: nil,
                engine: self.engine, imported: []
            )
        }
    }

    // MARK: - Output

    func testTranscribe_silentRecording_isEmptyNotPlaceholder() async {
        engine.installed = [model.id]
        engine.transcript = " [BLANK_AUDIO] "
        do {
            _ = try await IOSLocalTranscriptionModels.transcribe(
                at: audioURL, modelID: model.id, language: nil, engine: engine, imported: []
            )
            XCTFail("A silent recording must not produce text")
        } catch IOSBatchTranscriptionError.emptyTranscript {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertFalse(IOSLocalTranscriptionModels.isInUse(model.id))
    }

    func testTranscribe_recordsTheDownloadedModelForHistory() async throws {
        engine.installed = [model.id]
        engine.transcript = "  Hello world "

        let result = try await IOSLocalTranscriptionModels.transcribe(
            at: audioURL, modelID: model.id, language: "en-GB", engine: engine, imported: []
        )

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.modelIdentifier, model.id)
        XCTAssertEqual(engine.transcribedModels, [model.id])
        XCTAssertEqual(ModelCatalog.friendlyName(for: model.id), model.displayName)
    }

    // MARK: - Settings selection

    func testSelectingADownloadedModel_isLocalBatchAndRemembersTheRemoteModel() {
        engine.installed = [model.id]
        let settings = makeSettings()
        settings.selectRemoteTranscriptionMode(.batch)
        let remote = settings.batchTranscriptionModel
        XCTAssertFalse(IOSLocalTranscriptionModels.isDownloadedModelID(remote))

        settings.selectDownloadedTranscriptionModel(model.id)

        XCTAssertEqual(settings.batchTranscriptionModel, model.id)
        XCTAssertEqual(settings.transcriptionLocation, .local)
        XCTAssertEqual(settings.localTranscriptionMode, .batch)
        XCTAssertTrue(AppSettings.canRunBatchModel(model.id))

        settings.selectTranscriptionLocation(.remote)
        settings.selectRemoteTranscriptionMode(.batch)
        XCTAssertEqual(settings.batchTranscriptionModel, remote)

        settings.selectTranscriptionLocation(.local)
        settings.selectLocalTranscriptionMode(.batch)
        XCTAssertEqual(settings.batchTranscriptionModel, model.id)
    }

    func testCanRunBatchModel_requiresTheDownload() {
        XCTAssertFalse(AppSettings.canRunBatchModel(model.id))
        engine.installed = [model.id]
        XCTAssertTrue(AppSettings.canRunBatchModel(model.id))
    }

    private func assertThrows(
        _ expected: IOSLocalTranscriptionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as IOSLocalTranscriptionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
#endif
