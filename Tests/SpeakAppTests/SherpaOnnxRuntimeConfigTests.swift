import XCTest

import SpeakCore
@testable import SpeakApp

#if !APP_STORE
/// Maps catalogue sources to the sherpa-onnx runtime configuration the sidecar
/// is launched with, so a catalogue entry can never silently drift from the
/// decoder settings its model family needs.
final class SherpaOnnxRuntimeConfigTests: XCTestCase {

    func testSpecification_parakeetV3_usesOfflineNemoTransducerConfig() throws {
        let source = LocalStreamingModelSource(
            repoID: ParakeetLocalModels.tdtV3Int8RepoID,
            modelName: ParakeetLocalModels.tdtV3Int8ModelName,
            runtime: "sherpa-onnx streaming runtime",
            approximateSizeMB: ParakeetLocalModels.tdtV3Int8DownloadSizeMB,
            archiveURL: ParakeetLocalModels.tdtV3Int8ArchiveURL
        )

        let spec = try SherpaOnnxRuntimeManager.specification(for: source)
        let root = ParakeetLocalModels.tdtV3Int8ModelName

        XCTAssertEqual(spec.modelType, "nemo_transducer")
        XCTAssertEqual(spec.featureDim, 128)
        XCTAssertEqual(spec.tokens, "\(root)/tokens.txt")
        XCTAssertEqual(spec.encoder, "\(root)/encoder.int8.onnx")
        XCTAssertEqual(spec.decoder, "\(root)/decoder.int8.onnx")
        XCTAssertEqual(spec.joiner, "\(root)/joiner.int8.onnx")
        XCTAssertEqual(spec.archiveURL, ParakeetLocalModels.tdtV3Int8ArchiveURL)
        XCTAssertEqual(spec.archiveSHA256, ParakeetLocalModels.tdtV3Int8ArchiveSHA256)
    }

    func testSpecification_parakeetV3_backfillsPinnedArchiveURLForManualAdds() throws {
        let source = LocalStreamingModelSource(
            repoID: ParakeetLocalModels.tdtV3Int8RepoID,
            modelName: ParakeetLocalModels.tdtV3Int8ModelName
        )

        let spec = try SherpaOnnxRuntimeManager.specification(for: source)

        XCTAssertEqual(spec.archiveURL, ParakeetLocalModels.tdtV3Int8ArchiveURL)
        XCTAssertEqual(spec.archiveSHA256, ParakeetLocalModels.tdtV3Int8ArchiveSHA256)
    }

    func testSpecification_onlineZipformer_keepsOnlineTransducerDefaults() throws {
        let source = LocalStreamingModelSource(
            repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06",
            modelName: "streaming-zipformer-en-kroko-2025-08-06"
        )

        let spec = try SherpaOnnxRuntimeManager.specification(for: source)

        XCTAssertEqual(spec.modelType, "transducer")
        XCTAssertEqual(spec.featureDim, 80)
        XCTAssertNil(spec.archiveSHA256)
    }

    func testSpecification_nemotron_staysOnlineTransducer() throws {
        let source = LocalStreamingModelSource(
            repoID: "k2-fsa/sherpa-onnx",
            modelName: "sherpa-onnx-nemotron-speech-streaming-en-0.6b-1120ms-int8-2026-04-25"
        )

        let spec = try SherpaOnnxRuntimeManager.specification(for: source)

        XCTAssertEqual(spec.modelType, "transducer")
        XCTAssertEqual(spec.featureDim, 128)
    }

    func testSidecarScript_routesModelTypesToMatchingRecognizers() {
        let script = SherpaOnnxRuntimeManager.sidecarScript

        XCTAssertTrue(script.contains("--model-type"))
        XCTAssertTrue(script.contains("OnlineRecognizer.from_transducer"))
        XCTAssertTrue(script.contains("OfflineRecognizer.from_transducer"))
        XCTAssertTrue(script.contains("model_type=args.model_type"))
        XCTAssertTrue(script.contains("decoding_method=\"greedy_search\""))
    }
}
#endif
