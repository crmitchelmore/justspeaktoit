import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

private struct RecognizerCall {
    let count: Int
    let language: String?
}

final class DesktopLocalTranscriptionTests: XCTestCase {
    private final class Recognizer: DesktopLocalRecognizer, @unchecked Sendable {
        let reply: String
        private let lock = NSLock()
        private(set) var calls: [RecognizerCall] = []

        init(reply: String) { self.reply = reply }

        func transcribe(
            samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?
        ) async throws -> String {
            try Task.checkCancellation()
            lock.withLock { calls.append(RecognizerCall(count: samples.count, language: language)) }
            return reply
        }
    }

    func testWindowsProjectsOnlyPinnedCatalogueEntriesWithTheirIdentifiers() {
        let windows = DesktopLocalTranscription.models(host: .windows).map(\.catalogueID)
        XCTAssertEqual(windows, WhisperCppModels.all.map(\.catalogueID))
        XCTAssertTrue(Set(windows).isSubset(of: Set(ModelCatalog.localTranscription.map(\.id))))
        XCTAssertEqual(DesktopLocalTranscription.options(host: .windows).map(\.id), windows)
        XCTAssertTrue(DesktopLocalTranscription.options(host: .windows).allSatisfy {
            $0.displayName.hasSuffix("(on-device)") && !$0.displayName.contains("WhisperKit")
        })
        XCTAssertTrue(DesktopLocalTranscription.models(host: .unsupported).isEmpty)
        XCTAssertTrue(DesktopLocalTranscription.models(host: .macOS(channel: .appStore)).isEmpty,
                      "A Core ML host is not a whisper.cpp host")
        XCTAssertNil(DesktopLocalTranscription.model(for: "local/whisperkit/distil-large-v3", host: .windows))
        XCTAssertEqual(
            DesktopLocalTranscription.model(for: " local/whisperkit/base ", host: .windows)?.displayName, "Whisper Base"
        )
    }

    func testLinuxOffersTheSamePickerOptionsAsWindows() {
        let linux = DesktopLocalTranscription.options(host: .linux)
        let windows = DesktopLocalTranscription.options(host: .windows)
        XCTAssertEqual(linux.map(\.id), windows.map(\.id))
        XCTAssertEqual(linux.map(\.displayName), windows.map(\.displayName))
        XCTAssertEqual(linux.first?.displayName, "Whisper Tiny (on-device)")
        XCTAssertEqual(DesktopLocalTranscription.models(host: .linux), DesktopLocalTranscription.models(host: .windows))
        XCTAssertEqual(
            DesktopLocalTranscription.model(for: "local/whisperkit/small", host: .linux)?.artifact.filename,
            "ggml-small.bin"
        )
    }

    func testHistoryAndProfilesUseTheRuntimeNeutralName() {
        XCTAssertEqual(
            DesktopHistorySearch.modelDisplayName(for: "local/whisperkit/small"), "Whisper Small (on-device)"
        )
        XCTAssertEqual(DesktopHistorySearch.modelDisplayName(for: "openai/whisper-1"),
                       ModelCatalog.friendlyName(for: "openai/whisper-1"))
    }

    func testProfilesCanRunOnlyTheHostsLocalModels() {
        let capabilities = DesktopProfileCapabilities(
            batchModels: [], liveModels: [], polishModels: [],
            localModels: DesktopLocalTranscription.options(host: .windows)
        )
        XCTAssertTrue(capabilities.canRun(transcriptionModel: "local/whisperkit/base", routing: .localBatch))
        XCTAssertFalse(
            capabilities.canRun(transcriptionModel: "local/whisperkit/distil-large-v3", routing: .localBatch)
        )
        XCTAssertFalse(capabilities.canRun(transcriptionModel: "local/whisperkit/base", routing: .remoteBatch))
        XCTAssertFalse(DesktopProfileCapabilities.shared.canRun(
            transcriptionModel: "local/whisperkit/base", routing: .localBatch
        ))
    }

    func testModelSlotsKeepLocalRowsAcrossDiscovery() throws {
        let local = DesktopLocalTranscription.options(host: .windows)
        var slots = DesktopModelSlots(live: [], local: local)
        let localIDs = slots.entries.filter(\.isLocal).map(\.option.id)
        XCTAssertEqual(localIDs, local.map(\.id))
        XCTAssertTrue(slots.entries.filter(\.isLocal).allSatisfy { !$0.isLive })
        try slots.update(discovered: [], retaining: [])
        XCTAssertEqual(slots.entries.filter(\.isLocal).map(\.option.id), local.map(\.id))
        XCTAssertTrue(local.allSatisfy { option in
            slots.visibleIndices.contains { slots.entries[$0].option.id == option.id }
        })
    }

    func testLanguageHintsBecomeBareWhisperCodes() {
        XCTAssertNil(DesktopLocalTranscription.whisperLanguage(nil))
        XCTAssertNil(DesktopLocalTranscription.whisperLanguage("auto"))
        XCTAssertNil(DesktopLocalTranscription.whisperLanguage(" "))
        XCTAssertEqual(DesktopLocalTranscription.whisperLanguage("en-GB"), "en")
        XCTAssertEqual(DesktopLocalTranscription.whisperLanguage("pt_BR"), "pt")
        XCTAssertEqual(DesktopLocalTranscription.whisperLanguage("DE"), "de")
        XCTAssertEqual(DesktopLocalTranscription.whisperLanguage("yue"), "yue")
        XCTAssertNil(DesktopLocalTranscription.whisperLanguage("english"))
    }

    func testNonSpeechMarkersNeverBecomeTranscripts() {
        XCTAssertEqual(DesktopLocalTranscription.cleanTranscript(" [BLANK_AUDIO] "), "")
        XCTAssertEqual(DesktopLocalTranscription.cleanTranscript("(silence) [ Silence ] *music*"), "")
        XCTAssertEqual(DesktopLocalTranscription.cleanTranscript("  Hello\n  world. "), "Hello world.")
        XCTAssertEqual(DesktopLocalTranscription.cleanTranscript("(laughs) That was fun."), "(laughs) That was fun.")
    }

    func testSilentRecordingStaysEmptyWithoutRunningTheModel() async throws {
        let directory = try LocalModelTestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("silence.wav")
        try LocalModelTestFiles.wav(samples: [Int16](repeating: 3, count: 16_000)).write(to: audio)
        let recognizer = Recognizer(reply: "Thank you for watching.")
        let model = try XCTUnwrap(WhisperCppModels.all.first)

        let result = try await DesktopLocalTranscription.transcribe(
            audioURL: audio, model: model, modelFile: directory, language: nil, recognizer: recognizer
        )
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(result.duration, 1, accuracy: 0.0001)
        XCTAssertTrue(recognizer.calls.isEmpty)
    }

    func testSpeechIsTranscribedWithTheCatalogueIdentifier() async throws {
        let directory = try LocalModelTestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("tone.wav")
        let tone = (0..<8_000).map { Int16(8_000 * sin(Double($0) * 0.2)) }
        try LocalModelTestFiles.wav(samples: tone, listChunk: true).write(to: audio)
        let recognizer = Recognizer(reply: "  Ask not what your country can do for you. ")
        let model = try XCTUnwrap(WhisperCppModels.model(forCatalogueID: "local/whisperkit/base"))

        let result = try await DesktopLocalTranscription.transcribe(
            audioURL: audio, model: model, modelFile: directory, language: "en-US", recognizer: recognizer
        )
        XCTAssertEqual(result.text, "Ask not what your country can do for you.")
        XCTAssertEqual(result.modelIdentifier, "local/whisperkit/base")
        XCTAssertEqual(result.duration, 0.5, accuracy: 0.0001)
        XCTAssertEqual(recognizer.calls.first?.count, 8_000)
        XCTAssertEqual(recognizer.calls.first?.language, "en")
    }

    func testOtherAudioFormatsAreRefusedBeforeRecognition() throws {
        var stereo = LocalModelTestFiles.wav(samples: [1, 2, 3, 4])
        stereo[22] = 2
        XCTAssertThrowsError(try DesktopLocalAudio.parse(stereo)) {
            guard case .unsupportedAudio = $0 as? DesktopLocalTranscriptionError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try DesktopLocalAudio.parse(Data("not audio".utf8)))
        let parsed = try DesktopLocalAudio.parse(LocalModelTestFiles.wav(samples: [Int16.min, 0, Int16.max]))
        XCTAssertEqual(parsed.samples.count, 3)
        XCTAssertEqual(parsed.samples[0], -1)
        XCTAssertEqual(parsed.samples[2], Float(Int16.max) / 32_768, accuracy: 0.00001)
    }
}
