#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib
@testable import SpeakiOSLlama

/// Downloaded cleanup models on iOS (issue #1650): the prompt roles, empty
/// input, verification, failures that keep the transcript, and RAM gating.
final class IOSLocalCleanupTests: XCTestCase {
    private final class FakeEngine: IOSLocalCleanupEngine, @unchecked Sendable {
        var reply = "Cleaned."
        var error: Error?
        private(set) var calls: [(system: String, user: String)] = []

        func complete(
            modelFile: URL, systemPrompt: String, userMessage: String, timeout: TimeInterval
        ) async throws -> String {
            calls.append((systemPrompt, userMessage))
            if let error { throw error }
            return reply
        }

        func releaseMemory() {}
    }

    private var root: URL!
    private var engine: FakeEngine!
    private let model = LlamaCppModels.all.last!
    private let plenty: UInt64 = 8 << 30

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IOSLocalCleanupTests-\(UUID())")
        engine = FakeEngine()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func cleanup(digest: String? = nil, memory: UInt64? = nil) -> IOSLocalCleanup {
        let engine = self.engine
        let sha = digest ?? model.artifact.sha256
        return IOSLocalCleanup(
            engine: { engine }, verifier: IOSPinnedWeightsVerifier { _ in sha },
            physicalMemory: memory ?? plenty, root: root, timeout: 5
        )
    }

    /// A sparse file of the pinned size; the fake digest stands in for SHA-256.
    private func installModel() throws {
        let file = IOSLocalCleanupModels.fileURL(for: model, root: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(model.artifact.byteCount))
        try handle.close()
    }

    func testClean_sendsPolicyAsSystemAndTranscriptAsUser() async throws {
        try installModel()
        let result = try await cleanup().clean("um hello", modelID: model.catalogueID)

        XCTAssertEqual(result, "Cleaned.")
        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertTrue(engine.calls[0].system.hasPrefix(TranscriptCleanupPolicy.baseSystemPrompt))
        XCTAssertTrue(engine.calls[0].system.hasSuffix(LocalCleanupPrompt.engineConstraint))
        XCTAssertTrue(engine.calls[0].user.contains("um hello"))
        XCTAssertFalse(engine.calls[0].user.contains(TranscriptCleanupPolicy.baseSystemPrompt))
    }

    func testClean_emptyTranscriptStaysEmptyWithoutTheModel() async throws {
        let result = try await cleanup().clean("  ", modelID: model.catalogueID)

        XCTAssertEqual(result, "  ")
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testClean_missingOrMismatchedModelIsRefusedBeforeLoading() async throws {
        await assertThrows(.notDownloaded(model.displayName)) {
            try await self.cleanup().clean("hi", modelID: self.model.catalogueID)
        }
        try installModel()
        await assertThrows(.verificationFailed(model.displayName)) {
            try await self.cleanup(digest: "bad").clean("hi", modelID: self.model.catalogueID)
        }
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testClean_rejectsThinkingAndUnwrapsTranscriptObject() async throws {
        try installModel()
        engine.reply = "<think>Let me see</think>Hi."
        await assertThrows(.thinkingAloud(model.displayName)) {
            try await self.cleanup().clean("hi", modelID: self.model.catalogueID)
        }
        engine.reply = #"{"transcript": "Hi."}"#
        let result = try await cleanup().clean("hi", modelID: model.catalogueID)
        XCTAssertEqual(result, "Hi.")
    }

    func testOffered_largestModelNeedsEnoughMemory() throws {
        let large = try XCTUnwrap(IOSLocalCleanupModels.model(for: "local/post-processing/qwen3-1.7b-q4"))

        XCTAssertFalse(IOSLocalCleanupModels.offered(physicalMemory: 4 << 30).contains(large))
        XCTAssertTrue(IOSLocalCleanupModels.offered(physicalMemory: plenty).contains(large))
        XCTAssertEqual(IOSLocalCleanupModels.offered(physicalMemory: 4 << 30).count, LlamaCppModels.all.count - 1)
    }

    func testEngineErrors_mapToReasonsThatKeepTheTranscript() {
        func mapped(_ failure: LlamaRuntimeFailure, _ stage: LlamaRuntimeError.Stage) -> IOSLocalCleanupError {
            LlamaRuntimeCleanupEngine.cleanupError(
                LlamaRuntimeError(stage: stage, failure: failure, code: failure.rawValue), name: "M"
            )
        }
        XCTAssertEqual(mapped(.timedOut, .complete), .timedOut("M"))
        XCTAssertEqual(mapped(.aborted, .load), .stopped("M"))
        XCTAssertEqual(mapped(.context, .load), .loadFailed("M"))
        XCTAssertEqual(mapped(.decode, .complete), .runtimeFailed("M", code: 4))
        XCTAssertTrue(IOSLocalCleanupError.timedOut("M").localizedDescription.contains("original transcript"))
    }

    private func assertThrows(
        _ expected: IOSLocalCleanupError, _ body: () async throws -> String, line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? IOSLocalCleanupError, expected, line: line)
        }
    }
}
#endif
