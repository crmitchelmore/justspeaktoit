import Foundation
import XCTest
@testable import SpeakCore

/// whisper.cpp artefacts extend the shared catalogue; they never form a second
/// model list. These invariants make a new catalogue entry or a new pin fail
/// here until both sides agree.
final class WhisperCppModelsTests: XCTestCase {
    func testEveryPinnedModelIsASharedCatalogueEntryInCatalogueOrder() {
        let catalogue = ModelCatalog.localTranscription.map(\.id)
        let pinned = WhisperCppModels.all.map(\.catalogueID)
        XCTAssertEqual(Set(pinned).count, pinned.count, "One pin per catalogue entry")
        XCTAssertTrue(Set(pinned).isSubset(of: Set(catalogue)))
        XCTAssertEqual(pinned, catalogue.filter { pinned.contains($0) }, "Pins follow catalogue order")
        for id in pinned {
            XCTAssertEqual(ModelCatalog.localTranscription.first { $0.id == id }?.engine, .whisperKit)
        }
    }

    func testQualifiedSetIsExplicit() {
        // Distilled checkpoints have no upstream whisper.cpp weights of the
        // same checkpoint (turbo) or no chunked decoding in whisper.cpp; adding
        // one must be a deliberate, reviewed change to this list.
        XCTAssertEqual(WhisperCppModels.all.map(\.catalogueID), [
            "local/whisperkit/tiny", "local/whisperkit/base", "local/whisperkit/small",
            "local/whisperkit/large-v3-turbo"
        ])
        XCTAssertNil(WhisperCppModels.model(forCatalogueID: "local/whisperkit/distil-large-v3"))
        XCTAssertNil(WhisperCppModels.model(forCatalogueID: "local/whisperkit/distil-large-v3-turbo"))
    }

    func testArtefactsArePinnedByRevisionSizeAndDigest() {
        let revision = WhisperCppModels.revision
        XCTAssertEqual(revision.count, 40)
        for model in WhisperCppModels.all {
            let artifact = model.artifact
            XCTAssertEqual(artifact.url.scheme, "https")
            XCTAssertEqual(artifact.url.host, "huggingface.co")
            XCTAssertEqual(
                artifact.url.absoluteString,
                "https://huggingface.co/\(WhisperCppModels.repository)/resolve/\(revision)/\(artifact.filename)"
            )
            XCTAssertEqual(artifact.url.lastPathComponent, artifact.filename)
            XCTAssertTrue(artifact.filename.hasPrefix("ggml-") && artifact.filename.hasSuffix(".bin"))
            XCTAssertTrue(artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
            XCTAssertGreaterThan(artifact.byteCount, 10_000_000)
            XCTAssertEqual(artifact.license, "MIT")
            XCTAssertTrue(artifact.allowedHosts.contains("huggingface.co"))
            XCTAssertEqual(model.backend, .whisperCppGGML)
            XCTAssertFalse(model.displayName.contains("WhisperKit"), "A whisper.cpp host does not run WhisperKit")
        }
        XCTAssertEqual(Set(WhisperCppModels.all.map(\.artifact.sha256)).count, WhisperCppModels.all.count)
    }

    func testCatalogueEntriesGainTheWhisperCppBackendOnlyThroughAPin() {
        for entry in ModelCatalog.localTranscription {
            let pinned = WhisperCppModels.model(forCatalogueID: entry.id) != nil
            XCTAssertEqual(entry.backend, .whisperKitCoreML, "The Apple primary backend is unchanged")
            XCTAssertEqual(entry.backends.contains(.whisperCppGGML), pinned, entry.id)
        }
        // macOS keeps running Core ML for the same identifiers.
        let mac = LocalModelHostSupport.macOS(channel: .appStore)
        for entry in ModelCatalog.localTranscription {
            XCTAssertEqual(mac.preferredBackend(for: entry), .whisperKitCoreML)
        }
    }

    func testLookupTrimsAndIgnoresCase() {
        XCTAssertEqual(WhisperCppModels.model(forCatalogueID: " LOCAL/WhisperKit/Base ")?.displayName, "Whisper Base")
        XCTAssertNil(WhisperCppModels.model(forCatalogueID: "local/whisperkit/huggingface/x/y"))
    }
}
