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

        let spec = try SherpaOnnxModelSpecification.resolve(for: source)
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

        let spec = try SherpaOnnxModelSpecification.resolve(for: source)

        XCTAssertEqual(spec.archiveURL, ParakeetLocalModels.tdtV3Int8ArchiveURL)
        XCTAssertEqual(spec.archiveSHA256, ParakeetLocalModels.tdtV3Int8ArchiveSHA256)
    }

    func testSpecification_onlineZipformer_keepsOnlineTransducerDefaults() throws {
        let source = LocalStreamingModelSource(
            repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06",
            modelName: "streaming-zipformer-en-kroko-2025-08-06"
        )

        let spec = try SherpaOnnxModelSpecification.resolve(for: source)

        XCTAssertEqual(spec.modelType, "transducer")
        XCTAssertEqual(spec.featureDim, 80)
        XCTAssertNil(spec.archiveSHA256)
    }

    func testSpecification_nemotron_staysOnlineTransducer() throws {
        let source = LocalStreamingModelSource(
            repoID: "k2-fsa/sherpa-onnx",
            modelName: "sherpa-onnx-nemotron-speech-streaming-en-0.6b-1120ms-int8-2026-04-25"
        )

        let spec = try SherpaOnnxModelSpecification.resolve(for: source)

        XCTAssertEqual(spec.modelType, "transducer")
        XCTAssertEqual(spec.featureDim, 128)
    }

    func testSpecification_nemotron35_pinsArchiveRuntimeAndLanguagePrompt() throws {
        for variant in NemotronLocalModels.multilingualVariants {
            let source = try XCTUnwrap(
                ModelCatalog.localStreamingSources.first { $0.modelName == variant.modelName }
            )
            let spec = try SherpaOnnxModelSpecification.resolve(for: source)

            XCTAssertEqual(spec.modelType, "transducer")
            XCTAssertEqual(spec.featureDim, 128)
            XCTAssertEqual(spec.encoder, "\(variant.modelName)/encoder.int8.onnx")
            XCTAssertEqual(spec.archiveURL, variant.archiveURL)
            XCTAssertEqual(spec.archiveSHA256, variant.archiveSHA256)
            XCTAssertEqual(spec.minimumRuntimeVersion, NemotronLocalModels.minimumRuntimeVersion)
            XCTAssertTrue(spec.supportsLanguageHint)
            XCTAssertEqual(source.backend, .sherpaOnnx)
        }
    }

    func testSpecification_englishNemotron_keepsOlderRuntimeWithoutLanguagePrompt() throws {
        let source = LocalStreamingModelSource(
            repoID: "k2-fsa/sherpa-onnx",
            modelName: "sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25"
        )

        let spec = try SherpaOnnxModelSpecification.resolve(for: source)

        XCTAssertNil(spec.minimumRuntimeVersion)
        XCTAssertFalse(spec.supportsLanguageHint)
    }

    func testRuntimePin_satisfiesEveryModelMinimum() {
        XCTAssertTrue(
            SherpaOnnxRuntimeManager.isVersion(
                SherpaOnnxRuntimeManager.pinnedRuntimeVersion,
                atLeast: NemotronLocalModels.minimumRuntimeVersion
            )
        )
        XCTAssertFalse(SherpaOnnxRuntimeManager.isVersion("1.13.2", atLeast: "1.13.5"))
        XCTAssertTrue(SherpaOnnxRuntimeManager.isVersion("1.13.10", atLeast: "1.13.5"))
        XCTAssertTrue(SherpaOnnxRuntimeManager.isVersion("2.0", atLeast: "1.13.5"))
        XCTAssertFalse(SherpaOnnxRuntimeManager.isVersion("0", atLeast: "1.13.5"))
    }

    func testLanguageArguments_onlyForPromptedModelsAndExplicitChoices() {
        func bundle(hint: Bool) -> SherpaOnnxModelBundle {
            let url = URL(fileURLWithPath: "/tmp")
            return SherpaOnnxModelBundle(
                source: LocalStreamingModelSource(repoID: "k2-fsa/sherpa-onnx", modelName: "m"),
                directory: url, tokens: url, encoder: url, decoder: url, joiner: url,
                featureDim: 128, modelType: "transducer", supportsLanguageHint: hint
            )
        }
        XCTAssertEqual(
            SherpaOnnxLiveController.languageArguments(for: bundle(hint: true), language: "ja"),
            ["--language", "ja"]
        )
        XCTAssertEqual(SherpaOnnxLiveController.languageArguments(for: bundle(hint: true), language: nil), [])
        XCTAssertEqual(SherpaOnnxLiveController.languageArguments(for: bundle(hint: false), language: "ja"), [])
    }

    func testSidecarScript_setsLanguageOptionOnlyWhenProvided() {
        let script = SherpaOnnxSidecarScript.source

        XCTAssertTrue(script.contains("parser.add_argument(\"--language\", default=None)"))
        XCTAssertTrue(script.contains("if args.language:\n        # Language-ID"))
        XCTAssertTrue(script.contains("stream.set_option(\"language\", args.language)"))
    }

    func testSidecarScript_routesModelTypesToMatchingRecognizers() {
        let script = SherpaOnnxSidecarScript.source

        XCTAssertTrue(script.contains("--model-type"))
        XCTAssertTrue(script.contains("OnlineRecognizer.from_transducer"))
        XCTAssertTrue(script.contains("OfflineRecognizer.from_transducer"))
        XCTAssertTrue(script.contains("model_type=args.model_type"))
        XCTAssertTrue(script.contains("decoding_method=\"greedy_search\""))
    }

    // MARK: - Bounded offline decode contract (issue #679)

    func testSidecarScript_decouplesIngestionFromOfflineDecode() {
        let script = SherpaOnnxSidecarScript.source

        // A dedicated reader thread must always drain stdin so the pipe can
        // never fill and block the app's real-time audio queue behind
        // inference.
        XCTAssertTrue(script.contains("threading.Thread(target=reader"))
        XCTAssertTrue(script.contains("eof.set()"))
        // Partials decode a bounded tail window at an adaptive cadence, and
        // retention is explicitly capped rather than unbounded.
        XCTAssertTrue(script.contains("partial_window_samples = 16000 * 60"))
        XCTAssertTrue(script.contains("max_buffer_samples = 16000 * 60 * 60"))
        XCTAssertTrue(script.contains("last_decode_seconds * 2.0"))
        XCTAssertTrue(script.contains("emit(\"buffer_capped\""))
        // Retention is a deque of chunks evicted whole, so a post-cap read
        // never shifts the entire buffer under the lock.
        XCTAssertTrue(script.contains("buffered = collections.deque()"))
        XCTAssertTrue(script.contains("buffered.popleft()"))
        XCTAssertFalse(script.contains("del buffered[:"))
        // Partial progress is measured against samples received, not retained,
        // so partials continue once the cap holds the buffer at a fixed size.
        XCTAssertTrue(script.contains("received += len(samples)"))
        XCTAssertTrue(script.contains("available = received"))
        XCTAssertFalse(script.contains("available = len(buffered)"))
        // A cap reached just before EOF is still reported, before the final.
        XCTAssertTrue(script.contains("thread.join()\n    # The reader can reach the cap"))
        XCTAssertTrue(script.contains("report_cap_once()\n    with lock:\n        final_window = snapshot(None)"))
        // The final decode covers every retained sample and is announced.
        XCTAssertTrue(script.contains("emit(\"finalizing\""))
        XCTAssertTrue(script.contains("final_window = snapshot(None)"))
        // The old quadratic whole-buffer partial loop must not return.
        XCTAssertFalse(script.contains("samples_since_decode"))
    }

    func testFinalisationAllowance_scalesWithSessionDuration() {
        // Short sessions keep the historical ten-second floor…
        XCTAssertEqual(SherpaOnnxLiveController.finalisationAllowance(forSessionSeconds: 0), 10)
        XCTAssertEqual(SherpaOnnxLiveController.finalisationAllowance(forSessionSeconds: 30), 10)
        // …and long sessions get time proportional to what was recorded: a
        // quarter of the duration is six-fold headroom at the measured ~0.04
        // real-time factor.
        XCTAssertEqual(SherpaOnnxLiveController.finalisationAllowance(forSessionSeconds: 240), 60)
        XCTAssertEqual(SherpaOnnxLiveController.finalisationAllowance(forSessionSeconds: 1_200), 300)
    }
}
#endif
