import Foundation
import XCTest
@testable import SpeakCore

final class HuggingFaceWhisperModelTests: XCTestCase {
    private func model(
        repository: String = "owner/whisper", filename: String = "ggml-medium.bin",
        revision: String = String(repeating: "a", count: 40),
        bytes: Int64 = 1_024, digest: String = String(repeating: "b", count: 64)
    ) throws -> HuggingFaceWhisperModel {
        try HuggingFaceWhisperModel(
            repository: repository, filename: filename, revision: revision,
            byteCount: bytes, sha256: digest, license: "MIT"
        )
    }

    func testImmutableIdentityAndFriendlyNameSurviveRoundTrip() throws {
        let imported = try model()
        XCTAssertEqual(imported.id, "local/whispercpp/huggingface/" + String(repeating: "b", count: 64))
        XCTAssertEqual(imported.displayName, "Whisper medium from owner/whisper")
        XCTAssertEqual(try JSONDecoder().decode(
            HuggingFaceWhisperModel.self, from: JSONEncoder().encode(imported)
        ), imported)
        XCTAssertEqual(imported.artifact.url.path, "/owner/whisper/resolve/\(imported.revision)/ggml-medium.bin")
        XCTAssertEqual(try model(revision: String(repeating: "c", count: 40)).id, imported.id)
        XCTAssertNotEqual(try model(digest: String(repeating: "c", count: 64)).id, imported.id)
        XCTAssertEqual(ModelCatalog.friendlyName(for: imported.id), "Imported Whisper GGML (bbbbbbbb)")
        XCTAssertNil(HuggingFaceWhisperModel.fallbackDisplayName(
            for: HuggingFaceWhisperModel.identifierPrefix + "not-a-digest"
        ))
    }

    func testWindowsAndLinuxProjectOnlyGGMLNotCoreMLImports() throws {
        let imported = try model()
        let coreML = WhisperKitHuggingFaceModels.importedModel(repoID: "owner/whisper", modelName: "medium")
        XCTAssertTrue(LocalModelHostSupport.windows.canExecute(model: imported))
        XCTAssertTrue(LocalModelHostSupport.linux.canExecute(model: imported))
        XCTAssertFalse(LocalModelHostSupport.windows.canExecute(model: coreML))
        XCTAssertFalse(LocalModelHostSupport.linux.canExecute(model: coreML))
        XCTAssertEqual(coreML.backends, [.whisperKitCoreML])
        XCTAssertEqual(imported.model.backend, .whisperCppGGML)
        XCTAssertNil(WhisperCppModels.model(forCatalogueID: imported.id))
        XCTAssertEqual(WhisperCppModels.all.map(\.catalogueID), [
            "local/whisperkit/tiny", "local/whisperkit/base", "local/whisperkit/small",
            "local/whisperkit/large-v3-turbo"
        ])
    }

    func testMacIdentityMigrationNeverConvertsToPortableAuthority() throws {
        let old = WhisperKitHuggingFaceModels.modelID(repoID: "argmaxinc/whisperkit-coreml", modelName: "tiny")
        XCTAssertFalse(WhisperKitHuggingFaceModels.normalizedModelID(old)
            .hasPrefix(HuggingFaceWhisperModel.identifierPrefix))
        let imported = try model()
        XCTAssertEqual(WhisperKitHuggingFaceModels.normalizedModelID(imported.id), imported.id)
    }

    func testRejectsTraversalNULURLsEncodedSeparatorsAndAmbiguousPaths() {
        for repository in ["../repo", "owner/..", "owner//repo", "/owner/repo", "owner/repo/",
                           "owner\\repo", "owner/repo%2ffile", "owner/repo%5cfile",
                           "https://huggingface.co/owner/repo", "owner/repo\u{0000}"] {
            XCTAssertThrowsError(try model(repository: repository), repository)
        }
        for filename in ["../ggml-medium.bin", "dir/ggml-medium.bin", "ggml-medium.bin\u{0000}",
                         "ggml-medium%2f.bin", "ggml-medium\\file.bin", "ggml-medium.bin\n"] {
            XCTAssertThrowsError(try model(filename: filename), filename)
        }
    }

    func testRejectsUnsupportedAndUnqualifiedFormats() {
        for filename in ["model.mlmodelc", "model.onnx", "model.gguf", "model.bin", "ggml-distil-large-v3.bin",
                         "ggml-large-v1-turbo.bin", "ggml-small-q8_1.bin", "GGML-medium.bin"] {
            XCTAssertThrowsError(try model(filename: filename), filename)
        }
        XCTAssertNoThrow(try model(filename: "ggml-small.en-q5_1.bin"))
        XCTAssertNoThrow(try model(filename: "ggml-large-v3-turbo-q5_0.bin"))
    }

    func testRejectsUnpinnedMalformedOrUnboundedMetadataIncludingDecodedRecords() throws {
        for revision in ["main", String(repeating: "a", count: 39), String(repeating: "A", count: 40)] {
            XCTAssertThrowsError(try model(revision: revision))
        }
        for digest in ["", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            XCTAssertThrowsError(try model(digest: digest))
        }
        for bytes in [Int64(0), 47, HuggingFaceWhisperModel.maximumByteCount + 1] {
            XCTAssertThrowsError(try model(bytes: bytes))
        }
        let encoded = try JSONEncoder().encode(model())
        let tampered = try XCTUnwrap(String(bytes: encoded, encoding: .utf8))
            .replacingOccurrences(of: String(repeating: "a", count: 40), with: "main")
        XCTAssertThrowsError(try JSONDecoder().decode(HuggingFaceWhisperModel.self, from: Data(tampered.utf8)))
    }
}
