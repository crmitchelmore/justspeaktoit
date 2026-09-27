import Foundation
import XCTest
@testable import SpeakCore

final class HuggingFaceModelFilesTests: XCTestCase {
    private let revision = String(repeating: "a", count: 40)
    private let digest = String(repeating: "b", count: 64)

    func testRepositoryIdentifiersAreValidatedAndPastedURLsAccepted() {
        XCTAssertEqual(HuggingFaceModelFiles.normalizedRepoID(" ggerganov/whisper.cpp "), "ggerganov/whisper.cpp")
        XCTAssertEqual(
            HuggingFaceModelFiles.normalizedRepoID("https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/tree/main"),
            "unsloth/Qwen3-0.6B-GGUF"
        )
        for invalid in ["", "owner", "/repo", "owner/", "../etc", "owner/re po", "owner/-x", "o\u{0}/r", "a/b?c"] {
            XCTAssertNil(HuggingFaceModelFiles.normalizedRepoID(invalid), invalid)
        }
    }

    func testOnlySingleFileGGMLAndGGUFModelsAreImportable() {
        XCTAssertEqual(HuggingFaceModelFiles.kind(ofPath: "ggml-medium.en-q5_0.bin"), .whisperGGML)
        XCTAssertEqual(HuggingFaceModelFiles.kind(ofPath: "models/Qwen3-4B-Q4_K_M.gguf"), .llamaGGUF)
        for rejected in [
            "ggml-base-encoder.mlmodelc.zip", "model-00001-of-00003.gguf", "mmproj-model-f16.gguf", "pytorch_model.bin",
            "README.md", "../ggml-tiny.bin", "a//ggml-tiny.bin", "dir\\ggml-tiny.bin", "/ggml-tiny.bin",
            "ggml-base-coreml.bin"
        ] {
            XCTAssertNil(HuggingFaceModelFiles.kind(ofPath: rejected), rejected)
        }
    }

    func testListingPinsEachFileToTheRevisionAndItsLFSDigest() throws {
        let info = Data(#"{"sha":"\#(revision)","cardData":{"license":"mit"}}"#.utf8)
        let parsed = try HuggingFaceModelFiles.parseModelInfo(info)
        XCTAssertEqual(parsed.revision, revision)
        XCTAssertEqual(parsed.license, "mit")
        let tree = Data("""
        [{"type":"directory","path":"sub"},
         {"type":"file","path":"ggml-small.bin","size":134,"lfs":{"oid":"\(digest)","size":487601967}},
         {"type":"file","path":"ggml-tiny.bin","size":134,"lfs":{"oid":"\(digest.uppercased())","size":77691713}},
         {"type":"file","path":"sub/model-Q4_K_M.gguf","size":10,"lfs":{"oid":"\(digest)","size":1000}},
         {"type":"file","path":"ggml-base.bin","size":147951465},
         {"type":"file","path":"README.md","size":10}]
        """.utf8)
        let listing = try HuggingFaceModelFiles.parseTree(tree, repoID: "o/r", revision: revision, license: "mit")
        XCTAssertEqual(listing.candidates.map(\.path), ["sub/model-Q4_K_M.gguf", "ggml-tiny.bin", "ggml-small.bin"])
        XCTAssertEqual(listing.candidates[1].byteCount, 77_691_713, "The LFS size, not the pointer size")
        XCTAssertEqual(listing.candidates[1].sha256, digest, "Digests are normalised to lowercase")
        XCTAssertEqual(listing.skippedCount, 2, "A GGML file without an LFS digest cannot be verified")
        XCTAssertThrowsError(try HuggingFaceModelFiles.parseModelInfo(Data(#"{"sha":"main"}"#.utf8)))
        XCTAssertThrowsError(try HuggingFaceModelFiles.parseTree(Data("{}".utf8), repoID: "o/r", revision: revision,
                                                                 license: nil))
    }

    func testImportsDeriveStableIdentitiesPinnedArtefactsAndFriendlyNames() throws {
        let speech = ImportedLocalModelFile(candidate: .init(
            repoID: "ggerganov/whisper.cpp", revision: revision, path: "ggml-medium.en-q5_0.bin", byteCount: 539_212_467,
            sha256: digest, kind: .whisperGGML, license: "mit"
        ))
        XCTAssertEqual(speech.id, "local/whispercpp/huggingface/ggerganov/whisper-cpp/ggml-medium-en-q5-0-bin")
        XCTAssertTrue(speech.isValid)
        XCTAssertEqual(speech.displayName, "ggml-medium.en-q5_0 from ggerganov/whisper.cpp")
        let whisper = try XCTUnwrap(speech.whisperCppModel)
        XCTAssertFalse(whisper.supportsLiveStreaming, "Imports are never live-qualified")
        XCTAssertFalse(whisper.multilingual)
        XCTAssertEqual(whisper.quantization, "q5_0")
        XCTAssertEqual(
            whisper.artifact.url.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/ggml-medium.en-q5_0.bin"
        )
        XCTAssertNil(speech.llamaCppModel)
        XCTAssertEqual(
            ModelCatalog.friendlyName(for: speech.id), "Ggml Medium En Q5 0 Bin",
            "Without the import record the identifier still gets a specific name, never a generic label"
        )

        let cleanup = ImportedLocalModelFile(candidate: .init(
            repoID: "unsloth/Qwen3-4B-GGUF", revision: revision, path: "Qwen3-4B-Q4_K_M.gguf", byteCount: 2_500_000_000,
            sha256: digest, kind: .llamaGGUF, license: nil
        ))
        XCTAssertEqual(
            cleanup.id, LocalPostProcessingModel.huggingFaceModelID(repoID: "unsloth/Qwen3-4B-GGUF",
                                                                   filename: "Qwen3-4B-Q4_K_M.gguf"),
            "The same identity the macOS importer gives this file"
        )
        let llama = try XCTUnwrap(cleanup.llamaCppModel)
        XCTAssertEqual(llama.displayName, "Qwen3 4B Q4 K M from unsloth/Qwen3-4B-GGUF")
        XCTAssertEqual(llama.artifact.byteCount, 2_500_000_000)
        XCTAssertTrue(LocalPostProcessingModel.isDownloadedModelID(cleanup.id))

        let edited = String(decoding: try JSONEncoder().encode(speech), as: UTF8.self)
            .replacingOccurrences(of: "ggml-medium.en", with: "ggml-large-v3")
        let tampered = try JSONDecoder().decode(ImportedLocalModelFile.self, from: Data(edited.utf8))
        XCTAssertFalse(tampered.isValid, "An edited path no longer matches its identity")
    }
}
