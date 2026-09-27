import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

/// Local live projection, Hugging Face imports and local post-processing
/// for desktop hosts.
final class DesktopLocalModelParityTests: XCTestCase {
    override func tearDown() {
        DesktopLocalModelImports.register(DesktopLocalModelImports())
        super.tearDown()
    }

    // MARK: - Live projection

    func testOnlyQualifiedModelsAreOfferedLive() {
        let live = DesktopLocalTranscription.liveOptions(host: .windows)
        XCTAssertEqual(live.map(\.id), ["local/streaming/whispercpp/tiny", "local/streaming/whispercpp/base"])
        XCTAssertTrue(live.allSatisfy { $0.displayName.hasSuffix("(on-device, live)") })
        XCTAssertTrue(DesktopLocalTranscription.liveOptions(host: .unsupported).isEmpty)
        XCTAssertNil(DesktopLocalTranscription.liveModel(for: "local/streaming/whispercpp/small", host: .windows))
        XCTAssertEqual(
            DesktopLocalTranscription.downloadedModel(for: "local/streaming/whispercpp/base", host: .windows)?
                .catalogueID,
            "local/whisperkit/base", "Live and batch share one download"
        )
        XCTAssertEqual(
            DesktopHistorySearch.modelDisplayName(for: "local/streaming/whispercpp/tiny"),
            "Whisper Tiny (on-device, live)"
        )
    }

    func testSlotsSeparateLocalBatchAndLocalLive() throws {
        let local = DesktopLocalTranscription.options(host: .windows)
        let localLive = DesktopLocalTranscription.liveOptions(host: .windows)
        var slots = DesktopModelSlots(live: [], local: local, localLive: localLive)
        let liveEntries = slots.entries.filter { $0.isLive && $0.isLocal }
        XCTAssertEqual(liveEntries.map(\.option.id), localLive.map(\.id))
        XCTAssertEqual(slots.entries.filter { $0.isLocal && !$0.isLive }.map(\.option.id), local.map(\.id))
        try slots.update(discovered: [], retaining: [])
        XCTAssertEqual(slots.entries.filter { $0.isLive && $0.isLocal }.map(\.option.id), localLive.map(\.id))
    }

    func testImportedModelsGainAndLoseSlotsWithoutMovingOthers() throws {
        var slots = DesktopModelSlots(live: [], local: DesktopLocalTranscription.options(host: .windows))
        let before = slots.entries.map(\.option.id)
        let option = ModelCatalog.Option(
            id: "local/whispercpp/huggingface/owner/repo/ggml-x-bin", displayName: "x from owner/repo",
            latencyTier: .medium
        )
        XCTAssertTrue(slots.appendLocal(option))
        XCTAssertEqual(Array(slots.entries.map(\.option.id).prefix(before.count)), before)
        XCTAssertTrue(slots.visibleIndices.contains(before.count))
        slots.hideLocal(option.id)
        try slots.update(discovered: [], retaining: [])
        XCTAssertFalse(slots.visibleIndices.contains(before.count), "A removed import stays hidden after refresh")
        XCTAssertTrue(slots.appendLocal(option))
        XCTAssertEqual(slots.entries.count, before.count + 1, "Re-importing reuses the slot")
        XCTAssertTrue(slots.visibleIndices.contains(before.count))
    }

    // MARK: - Hugging Face imports

    private static func fetcher(_ responses: [String: String]) -> HuggingFaceModelResolver.Fetch {
        { url in
            guard let body = responses[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
            return Data(body.utf8)
        }
    }

    private let sha = String(repeating: "a", count: 40)
    private let digest = String(repeating: "b", count: 64)

    func testResolvingPinsRevisionSizeAndDigest() async throws {
        let fetch = Self.fetcher([
            "https://huggingface.co/api/models/owner/repo/revision/main":
                #"{"sha":"\#(sha)","cardData":{"license":"apache-2.0"}}"#,
            "https://huggingface.co/api/models/owner/repo/tree/\(sha)/q":
                #"[{"type":"file","path":"q/Model-Q4_K_M.gguf","size":134,"#
                    + #""lfs":{"oid":"\#(digest)","size":987654321}}]"#
        ])
        let model = try await HuggingFaceModelResolver.resolve(
            repoID: " owner/repo ", path: "q/Model-Q4_K_M.gguf", kind: .postProcessing, fetch: fetch
        )
        XCTAssertEqual(model.identifier, "local/post-processing/huggingface/owner/repo/model-q4-k-m-gguf")
        XCTAssertEqual(model.revision, sha)
        XCTAssertEqual(model.byteCount, 987_654_321)
        XCTAssertEqual(model.sha256, digest)
        XCTAssertEqual(model.license, "apache-2.0")
        XCTAssertEqual(model.displayName, "Model Q4 K M from owner/repo")
        let artifact = try XCTUnwrap(model.artifact)
        XCTAssertEqual(
            artifact.url.absoluteString, "https://huggingface.co/owner/repo/resolve/\(sha)/q/Model-Q4_K_M.gguf"
        )
        XCTAssertEqual(artifact.filename, "Model-Q4_K_M.gguf")
        XCTAssertEqual(model.languageModel?.identifier, model.identifier)
        XCTAssertNil(model.whisperModel)
    }

    func testFilesWithoutAPublishedDigestAreRefused() async {
        let fetch = Self.fetcher([
            "https://huggingface.co/api/models/owner/repo/revision/main": #"{"sha":"\#(sha)"}"#,
            "https://huggingface.co/api/models/owner/repo/tree/\(sha)":
                #"[{"type":"file","path":"ggml-small.bin","size":12}]"#
        ])
        do {
            _ = try await HuggingFaceModelResolver.resolve(
                repoID: "owner/repo", path: "ggml-small.bin", kind: .transcription, fetch: fetch
            )
            XCTFail("A file without LFS metadata has no SHA-256 to verify")
        } catch {
            XCTAssertEqual(error as? DesktopLocalModelImportError, .notLargeFileStorage("ggml-small.bin"))
        }
        do {
            _ = try await HuggingFaceModelResolver.resolve(
                repoID: "owner/repo", path: "missing.bin", kind: .transcription, fetch: fetch
            )
            XCTFail("A missing file must not import")
        } catch {
            XCTAssertEqual(error as? DesktopLocalModelImportError, .notFound("missing.bin"))
        }
    }

    func testValidationRejectsUnsafeOrMismatchedInput() {
        XCTAssertThrowsError(
            try HuggingFaceModelResolver.validate(repoID: "repo", path: "a.gguf", kind: .postProcessing)
        )
        XCTAssertThrowsError(
            try HuggingFaceModelResolver.validate(repoID: "a/b/c", path: "a.gguf", kind: .postProcessing)
        )
        XCTAssertThrowsError(
            try HuggingFaceModelResolver.validate(repoID: "a/b", path: "../a.gguf", kind: .postProcessing)
        )
        XCTAssertThrowsError(try HuggingFaceModelResolver.validate(repoID: "a/b", path: "a.bin", kind: .postProcessing))
        XCTAssertThrowsError(try HuggingFaceModelResolver.validate(repoID: "a/b", path: "a.gguf", kind: .transcription))
        XCTAssertEqual(HuggingFaceModelResolver.kind(forPath: "X.GGUF"), .postProcessing)
        XCTAssertEqual(HuggingFaceModelResolver.kind(forPath: "ggml-base.en.bin"), .transcription)
        XCTAssertNil(HuggingFaceModelResolver.kind(forPath: "model.onnx"))
    }

    func testImportedWhisperModelsResolveForTranscriptionAndHistory() throws {
        let imported = DesktopImportedLocalModel(
            kind: .transcription, repoID: "ggerganov/whisper.cpp", path: "ggml-small.en-q5_1.bin", revision: sha,
            byteCount: 190_000_000, sha256: digest, license: "mit"
        )
        var imports = DesktopLocalModelImports()
        imports.add(imported)
        DesktopLocalModelImports.register(imports)
        XCTAssertEqual(imported.identifier, "local/whispercpp/huggingface/ggerganov/whisper-cpp/ggml-small-en-q5-1-bin")
        XCTAssertEqual(imported.displayName, "small.en q5 1 from ggerganov/whisper.cpp")
        let model = try XCTUnwrap(DesktopLocalTranscription.model(for: imported.identifier, host: .windows))
        XCTAssertFalse(model.liveQualified, "Imports are never offered live")
        XCTAssertEqual(DesktopHistorySearch.modelDisplayName(for: imported.identifier), imported.displayName)
        XCTAssertNil(DesktopLocalTranscription.model(for: imported.identifier, host: .unsupported))
        // Without the store, History still derives a specific name.
        DesktopLocalModelImports.register(DesktopLocalModelImports())
        XCTAssertEqual(
            DesktopHistorySearch.modelDisplayName(for: imported.identifier),
            "ggml-small-en-q5-1-bin from ggerganov/whisper-cpp"
        )
    }

    func testTheImportStoreRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var imports = DesktopLocalModelImports()
        imports.add(DesktopImportedLocalModel(
            kind: .postProcessing, repoID: "a/b", path: "m.gguf", revision: sha, byteCount: 5, sha256: digest,
            license: nil
        ))
        try imports.save(to: directory) { data, url in try data.write(to: url) }
        XCTAssertEqual(DesktopLocalModelImports.load(from: directory), imports)
        imports.remove(identifier: imports.models[0].identifier)
        XCTAssertTrue(imports.models.isEmpty)
        XCTAssertTrue(DesktopLocalModelImports.load(from: directory.appendingPathComponent("none")).models.isEmpty)
    }

    // MARK: - Local post-processing

    private final class LanguageModel: DesktopLocalLanguageModel, @unchecked Sendable {
        let reply: String
        private let lock = NSLock()
        private(set) var systemPrompts: [String] = []
        private(set) var userMessages: [String] = []
        init(reply: String) { self.reply = reply }
        func generate(_ request: DesktopLocalGeneration, model: LlamaCppModel, modelFile: URL) async throws -> String {
            lock.withLock {
                systemPrompts.append(request.systemPrompt)
                userMessages.append(request.userMessage)
            }
            return reply
        }
    }

    func testALocalLanguageModelReceivesTheUsersPromptAsItsSystemInstruction() async throws {
        let model = try XCTUnwrap(LlamaCppModels.all.last)
        let generator = LanguageModel(reply: "<think>hm</think> Hello. World.")
        let options = DesktopPostProcessing.Options(
            mode: .local, modelIdentifier: model.identifier, customPrompt: "One full stop after each word.",
            outputLanguage: "British English"
        )
        let outcome = try await DesktopPostProcessing.processLocally(
            rawText: "hello world", options: options, model: model, modelFile: URL(fileURLWithPath: "/m.gguf"),
            languageModel: generator
        )
        XCTAssertEqual(outcome.processedText, "Hello. World.")
        XCTAssertEqual(outcome.original, "hello world")
        XCTAssertEqual(outcome.modelIdentifier, model.identifier)
        XCTAssertTrue(generator.systemPrompts.first?.hasPrefix("One full stop after each word.") == true)
        XCTAssertEqual(generator.userMessages.first, TranscriptCleanupPolicy.userMessage(transcript: "hello world"))
    }

    func testEmptyInputStaysEmptyAndNeverRunsTheModel() async throws {
        let model = try XCTUnwrap(LlamaCppModels.all.last)
        let generator = LanguageModel(reply: "Thank you for watching.")
        for text in ["", "   ", "[BLANK_AUDIO]"] {
            let outcome = try await DesktopPostProcessing.processLocally(
                rawText: text, options: .init(mode: .local, modelIdentifier: model.identifier), model: model,
                modelFile: URL(fileURLWithPath: "/m.gguf"), languageModel: generator
            )
            XCTAssertEqual(outcome.processedText, "")
        }
        XCTAssertTrue(generator.systemPrompts.isEmpty)
    }

    func testBuiltInRulesIgnoreThePromptAndNeedNoModel() async throws {
        let options = DesktopPostProcessing.Options(
            mode: .local, modelIdentifier: DesktopLocalPostProcessing.builtInRulesID, customPrompt: "Shout."
        )
        let outcome = try await DesktopPostProcessing.processLocally(
            rawText: "hello  world .", options: options, model: nil, modelFile: nil, languageModel: nil
        )
        XCTAssertEqual(outcome.processedText, TranscriptPostProcessingPolicy.processLocally("hello  world ."))
        XCTAssertNil(outcome.systemPrompt)
        XCTAssertFalse(DesktopLocalPostProcessing.usesPrompt(DesktopLocalPostProcessing.builtInRulesID))
        XCTAssertTrue(DesktopLocalPostProcessing.usesPrompt("local/post-processing/qwen3-0.6b-q4"))
        XCTAssertTrue(DesktopLocalPostProcessing.builtInRulesOption.description?.contains("ignores the prompt") == true)
    }

    func testAnEmptyModelReplyFailsInsteadOfErasingTheTranscript() async throws {
        let model = try XCTUnwrap(LlamaCppModels.all.first)
        do {
            _ = try await DesktopPostProcessing.processLocally(
                rawText: "hello", options: .init(mode: .local, modelIdentifier: model.identifier), model: model,
                modelFile: URL(fileURLWithPath: "/m.gguf"), languageModel: LanguageModel(reply: "<think>only")
            )
            XCTFail("An empty reply must not replace the transcript")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, DesktopPostProcessingError.emptyLocalResponse.localizedDescription
            )
        }
    }

    func testProjectionAndMigrationKeepLocalChoicesLocal() {
        XCTAssertEqual(
            DesktopLocalPostProcessing.models(host: .windows).map(\.identifier), LlamaCppModels.all.map(\.identifier)
        )
        XCTAssertTrue(DesktopLocalPostProcessing.models(host: .unsupported).isEmpty)
        let local = DesktopPostProcessing.migrated(.init(mode: .local, modelIdentifier: "local/post-processing/rules"))
        XCTAssertEqual(local.mode, .local)
        XCTAssertEqual(local.modelIdentifier, "local/post-processing/rules")
        let bogus = DesktopPostProcessing.migrated(.init(mode: .local, modelIdentifier: "openai/gpt-5.4-nano"))
        XCTAssertEqual(bogus.mode, .disabled)
        XCTAssertEqual(
            DesktopLocalPostProcessing.displayName(for: "local/post-processing/smollm2-360m-instruct-q4"),
            "SmolLM2 360M Instruct Q4"
        )
    }
}
