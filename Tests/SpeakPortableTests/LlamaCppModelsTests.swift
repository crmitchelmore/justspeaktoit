import Foundation
import XCTest
@testable import SpeakCore

/// GGUF pins extend the shared cleanup catalogue; they never form a second
/// model list, and a new catalogue entry must be pinned deliberately.
final class LlamaCppModelsTests: XCTestCase {
    func testEveryCatalogueCleanupModelIsPinnedInCatalogueOrder() {
        XCTAssertEqual(LlamaCppModels.all.map(\.catalogueID), ModelCatalog.localPostProcessing.map(\.id))
        for (pinned, entry) in zip(LlamaCppModels.all, ModelCatalog.localPostProcessing) {
            XCTAssertEqual(pinned.displayName, entry.displayName)
            XCTAssertEqual(pinned.summary, entry.description)
            XCTAssertEqual(pinned.artifact.filename, entry.filename)
            XCTAssertEqual(pinned.backend, .llamaCppGGUF)
            XCTAssertEqual(entry.backend, .llamaCppGGUF)
        }
    }

    func testArtefactsArePinnedByRevisionSizeAndDigest() throws {
        for model in LlamaCppModels.all {
            let entry = try XCTUnwrap(ModelCatalog.localPostProcessing.first { $0.id == model.catalogueID })
            let artifact = model.artifact
            let components = artifact.url.path.split(separator: "/").map(String.init)
            XCTAssertEqual(artifact.url.host, "huggingface.co")
            XCTAssertEqual(components.prefix(3).joined(separator: "/"), entry.repoID + "/resolve")
            XCTAssertTrue(HuggingFaceModelFiles.isRevision(components[3]), "Immutable revision, never main")
            XCTAssertEqual(components.last, entry.filename)
            XCTAssertTrue(artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
            // The catalogue's approximate size stays within 25% of the pinned bytes.
            let megabytes = Double(artifact.byteCount) / 1_048_576
            XCTAssertEqual(megabytes, Double(try XCTUnwrap(entry.approximateSizeMB)), accuracy: megabytes * 0.25)
            XCTAssertEqual(artifact.license, "Apache-2.0")
            XCTAssertTrue(artifact.allowedHosts.contains(".hf.co"))
        }
        XCTAssertEqual(Set(LlamaCppModels.all.map(\.artifact.sha256)).count, LlamaCppModels.all.count)
    }

    func testLookupIsTrimmedAndCaseInsensitiveAndRulesAreNotADownload() {
        XCTAssertEqual(
            LlamaCppModels.model(forCatalogueID: " LOCAL/post-processing/qwen3-0.6b-q4 ")?.displayName, "Qwen3 0.6B Q4"
        )
        XCTAssertNil(LlamaCppModels.model(forCatalogueID: LocalPostProcessingModel.builtInRulesModelID))
    }

    func testSharedPromptFramingKeepsTheCallersPromptAndStripsReasoning() {
        let custom = "Put one full stop after every word."
        let instruction = LocalPostProcessingPrompt.systemInstruction("  \(custom)\n")
        XCTAssertTrue(instruction.hasPrefix(custom))
        XCTAssertTrue(instruction.hasSuffix(LocalPostProcessingPrompt.engineConstraint))
        XCTAssertEqual(LocalPostProcessingPrompt.sanitizedOutput("<think>plan</think>\n Hello. World. "), "Hello. World.")
        XCTAssertEqual(LocalPostProcessingPrompt.sanitizedOutput("Hi.<think>never closed"), "Hi.")
        XCTAssertEqual(LocalPostProcessingPrompt.sanitizedOutput("</think>Done."), "Done.")
        XCTAssertEqual(LocalPostProcessingPrompt.maximumOutputTokens(for: "one two"), 1_024)
        XCTAssertEqual(
            LocalPostProcessingPrompt.maximumOutputTokens(for: String(repeating: "word ", count: 5_000)), 8_192
        )
    }
}
