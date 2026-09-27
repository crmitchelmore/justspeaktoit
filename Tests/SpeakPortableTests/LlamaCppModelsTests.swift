import Foundation
import XCTest
@testable import SpeakCore

/// llama.cpp artefacts pin the shared GGUF catalogue; they never form a
/// second list of names, repositories or files.
final class LlamaCppModelsTests: XCTestCase {
    func testEveryPinIsACatalogueEntryInCatalogueOrder() throws {
        let catalogue = ModelCatalog.localPostProcessing
        XCTAssertEqual(LlamaCppModels.all.map(\.identifier), catalogue.map(\.id), "Every catalogue entry is pinned")
        for model in LlamaCppModels.all {
            let entry = try XCTUnwrap(catalogue.first { $0.id == model.identifier })
            XCTAssertEqual(model.displayName, entry.displayName)
            XCTAssertEqual(model.summary, entry.description)
            XCTAssertEqual(model.artifact.filename, entry.filename)
            XCTAssertEqual(model.backend, .llamaCppGGUF)
        }
    }

    func testArtefactsArePinnedByRevisionSizeAndDigest() throws {
        for model in LlamaCppModels.all {
            let artifact = model.artifact
            let entry = try XCTUnwrap(ModelCatalog.localPostProcessing.first { $0.id == model.identifier })
            let url = artifact.url.absoluteString
            XCTAssertTrue(url.hasPrefix("https://huggingface.co/\(entry.repoID)/resolve/"), url)
            let revision = url.components(separatedBy: "/resolve/")[1].components(separatedBy: "/")[0]
            XCTAssertNotNil(revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression), url)
            XCTAssertEqual(artifact.url.lastPathComponent, artifact.filename)
            XCTAssertNotNil(artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
            XCTAssertTrue(artifact.allowedHosts.contains(".hf.co"))
            // Desktop hosts show these exact bytes, not the catalogue's estimate.
            XCTAssertGreaterThan(artifact.byteCount, 100_000_000, model.identifier)
            XCTAssertEqual(artifact.license, "Apache-2.0")
        }
        XCTAssertEqual(Set(LlamaCppModels.all.map(\.artifact.sha256)).count, LlamaCppModels.all.count)
    }

    func testHuggingFaceURLsEncodeEachComponent() {
        XCTAssertEqual(
            LlamaCppModels.huggingFaceURL(repoID: "owner/repo", revision: "abc", filename: "dir/My File.gguf")?
                .absoluteString,
            "https://huggingface.co/owner/repo/resolve/abc/dir/My%20File.gguf"
        )
        XCTAssertNil(LlamaCppModels.huggingFaceURL(repoID: "no-owner", revision: "abc", filename: "a.gguf"))
        XCTAssertEqual(LlamaCppModels.model(for: " LOCAL/post-processing/Qwen3-0.6B-Q4 ")?.displayName, "Qwen3 0.6B Q4")
        XCTAssertNil(LlamaCppModels.model(for: LocalPostProcessingModel.builtInRulesModelID))
    }
}

final class LocalLanguageModelPromptTests: XCTestCase {
    func testTheUsersPromptIsTheSystemInstruction() {
        let custom = "Put one full stop after each word."
        let prompt = LocalLanguageModelPrompt.systemPrompt(customPrompt: custom, outputLanguage: "British English")
        XCTAssertTrue(prompt.hasPrefix(custom), "The custom prompt leads, verbatim")
        XCTAssertFalse(prompt.contains(TranscriptCleanupPolicy.baseSystemPrompt))
        XCTAssertTrue(prompt.contains("British English"))
        XCTAssertTrue(prompt.hasSuffix(LocalLanguageModelPrompt.localEngineConstraint))
    }

    func testNoPromptUsesTheDefaultCleanupPolicy() {
        let prompt = LocalLanguageModelPrompt.systemPrompt(customPrompt: "  ", outputLanguage: nil)
        XCTAssertTrue(prompt.hasPrefix(TranscriptCleanupPolicy.baseSystemPrompt))
        XCTAssertEqual(
            LocalLanguageModelPrompt.userMessage(transcript: "hi"), TranscriptCleanupPolicy.userMessage(transcript: "hi")
        )
    }

    func testOutputSanitisingAndBudget() {
        XCTAssertEqual(LocalLanguageModelPrompt.sanitizedOutput("<think>plan</think>\n Hello. "), "Hello.")
        XCTAssertEqual(LocalLanguageModelPrompt.sanitizedOutput("Hi</think>"), "Hi")
        XCTAssertEqual(LocalLanguageModelPrompt.sanitizedOutput("<think>never closed"), "")
        XCTAssertEqual(LocalLanguageModelPrompt.maximumOutputTokens(for: ""), 256)
        XCTAssertEqual(LocalLanguageModelPrompt.maximumOutputTokens(for: "a b c"), 268)
        XCTAssertEqual(
            LocalLanguageModelPrompt.maximumOutputTokens(for: String(repeating: "w ", count: 5_000)), 4_096
        )
    }
}
