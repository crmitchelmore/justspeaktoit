import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import SpeakTestSupport
import XCTest

extension DesktopHostVoicePronunciationTests {
    // Keep all source/action ownership assertions in one end-to-end journey.
    // swiftlint:disable:next function_body_length
    func testIPA_AllSourceKindsReadGenerateFreshExportSendActualAzureBytesAndKeepRawOwnership() async throws {
        let selected = try await configureIPAVoice()
        let sources = try await sourcesWithHistory()
        let before = try await historyBytes()
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let wav = try VoicePronunciationProbe.audio()
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)), wav)
        }
        installAzureReadTransport(session)
        for source in sources {
            await controller.readVoiceSource(source)
            let read = await controller.readAloudState.task
            await read?.value
            XCTAssertEqual(FakeLog.shared.allStatuses.last, "Finished reading aloud.")
            await generateIPAVoice(source, session: session)
            let result = try await generated()
            XCTAssertEqual(result.source, source)
            XCTAssertEqual(result.voice, selected)
            XCTAssertEqual(result.audio.wav, wav)
            let destination = exportDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            await controller.exportVoiceSource(source, path: destination.path) { input, selection, credential in
                try await Self.azurePhonemeAudio(input, selection: selection, credential: credential, session: session)
            }
            let export = await controller.readAloudState.exportTask
            await export?.value
            XCTAssertEqual(try Data(contentsOf: destination), wav)
        }
        let expected = try AzureSpeechVoiceAPI.ssmlBody(text: ipaToken, voice: selected.id, useSSML: true)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 12)
        for request in StubURLProtocol.recordedRequests {
            XCTAssertEqual(StubURLProtocol.body(of: request), Data(expected.utf8))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"),
                           "synthetic-pronunciation-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Microsoft-OutputFormat"), "riff-24khz-16bit-mono-pcm")
        }
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.map(\.source.source), sources.map(\.source))
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.map(\.source.recordID), sources.map(\.recordID))
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.map(\.source.text), Array(repeating: ipaToken, count: 4))
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, Array(repeating: selected.apiKeyIdentifier, count: 12))
        let usage = await controller.voiceUsage.records
        XCTAssertEqual(usage?.count, 12)
        XCTAssertEqual(usage?.map(\.source), sources.flatMap { Array(repeating: $0.source, count: 3) })
        XCTAssertEqual(usage?.map(\.historyRecordID), sources.flatMap { Array(repeating: $0.recordID, count: 3) })
        XCTAssertEqual(usage?.map(\.inputCharacters), Array(repeating: ipaToken.unicodeScalars.count, count: 12))
        XCTAssertEqual(usage?.map(\.usesSSML), Array(repeating: true, count: 12))
        XCTAssertEqual(usage?.map(\.modelID), Array(repeating: selected.modelID, count: 12))
        XCTAssertEqual(usage?.map(\.voiceID), Array(repeating: selected.id, count: 12))
        XCTAssertEqual(usage?.map(\.outcome), Array(repeating: .completed, count: 12))
        XCTAssertEqual(usage?.map(\.audioDuration), Array(repeating: 0.01, count: 12))
        XCTAssertEqual(FakeSpeech.shared.events, Array(repeating: ["begin", "play", "end"], count: 4).flatMap { $0 })
        let after = try await historyBytes()
        XCTAssertEqual(after, before)
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }

    func testIPA_ExplicitTagsAndEntityFragmentsBypassCorruptDictionaryAcrossAllActionsByteForByte() async throws {
        let selected = try await configureIPAVoice()
        let file = directory.appendingPathComponent("pronunciation.json")
        let raw = Data("synthetic corrupt dictionary".utf8)
        try raw.write(to: file)
        await controller.installPronunciationLoad(nil)
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let wav = try VoicePronunciationProbe.audio()
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)), wav)
        }
        installAzureReadTransport(session)
        let authored = [" \n<speak>Token &amp; text</speak>", "<prosody rate='slow'>Token</prosody>",
                        "Token <phoneme alphabet='ipa' ph='Token'>Token</phoneme><break time='1s'/>",
                        "Token &amp; text", "Token &#38; text", "Token &#x26; text", "&lt;speak&gt;",
                        "Token &unknown; text", "Token &custom:entity; text"]
        for text in authored {
            let source = try VoiceOutputSourceSnapshot(source: .textFile, text: text)
            await controller.readVoiceSource(source)
            let read = await controller.readAloudState.task
            await read?.value
            await generateIPAVoice(source, session: session)
            let result = try await generated()
            XCTAssertEqual(result.source, source)
            let destination = exportDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            await controller.exportVoiceSource(source, path: destination.path) { input, selection, credential in
                XCTAssertEqual(input, source)
                return try await Self.azurePhonemeAudio(
                    input, selection: selection, credential: credential, session: session)
            }
            let export = await controller.readAloudState.exportTask
            await export?.value
            XCTAssertEqual(try Data(contentsOf: destination), wav)
            let expected = try AzureSpeechVoiceAPI.ssmlBody(text: text, voice: selected.id, useSSML: true)
            for request in StubURLProtocol.recordedRequests.suffix(3) {
                XCTAssertEqual(StubURLProtocol.body(of: request), Data(expected.utf8))
            }
        }
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.map(\.source.text), authored)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, authored.count * 3)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys,
                       Array(repeating: selected.apiKeyIdentifier, count: authored.count * 3))
        let load = await controller.vocabularyLoad
        XCTAssertNil(load)
        XCTAssertEqual(try Data(contentsOf: file), raw)
        try assertPlaybackFilesEmpty()
        await assertSettled()
    }

    func testIPA_DisabledSSMLKeepsOrdinaryReplacementAndMAIDoesNotInferPhonemes() async throws {
        _ = try await configureIPAVoice()
        let disabled = await controller.saveVoiceSynthesisOptions(try .init(useSSML: false))
        XCTAssertTrue(disabled)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Token")
        await generate(source)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.last?.source.text, "Token Token")
        let mai = DesktopSpeechVoice.azureMAI(AzureMAIVoiceCatalog.voices[0])
        await controller.selectVoiceOutput(mai)
        let enabled = await controller.saveVoiceSynthesisOptions(try .init(useSSML: true))
        XCTAssertTrue(enabled)
        FakeLog.shared.setKey("synthetic-pronunciation-key", name: mai.apiKeyIdentifier)
        let file = directory.appendingPathComponent("pronunciation.json")
        let raw = Data("synthetic corrupt MAI dictionary".utf8)
        try raw.write(to: file)
        await controller.installPronunciationLoad(nil)
        await generate(source)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.last?.source, source)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.last?.selection.voice, mai)
        XCTAssertEqual(VoicePronunciationProbe.shared.calls.count, 2)
        XCTAssertEqual(VoicePronunciationProbe.shared.keys.count, 2)
        XCTAssertEqual(try Data(contentsOf: file), raw)
        XCTAssertThrowsError(try DesktopSpeechSelection(voice: voice, options: .init(useSSML: true)))
    }

    func testIPA_PlainMetacharactersAndRegexProducedMarkupAreEscapedExactlyOnceInActualRequest() async throws {
        let selected = try await configureIPAVoice()
        try await saveEntries([
            entry,
            .init(word: "(猫)(12)", pronunciation: "unused", replacement: "<$2&$1>", isRegex: true)
        ])
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let wav = try VoicePronunciationProbe.audio()
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)), wav)
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Token & a < b 猫12")
        await generateIPAVoice(source, session: session)
        let expected = try AzureSpeechVoiceAPI.ssmlBody(
            text: ipaToken + " &amp; a &lt; b &lt;12&amp;猫&gt;", voice: selected.id, useSSML: true)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(StubURLProtocol.body(of: request), Data(expected.utf8))
        XCTAssertEqual(VoicePronunciationProbe.shared.keys, [selected.apiKeyIdentifier])
        let result = try await generated()
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.audio.wav, wav)
        await assertSettled()
    }
}

extension DesktopHostVoicePronunciationTests {
    var ipaToken: String { #"<phoneme alphabet="ipa" ph="synthetic">Token</phoneme>"# }

    @discardableResult
    func configureIPAVoice() async throws -> DesktopSpeechVoice {
        let selected = DesktopSpeechVoice.azureNeural(AzureNeuralVoiceCatalog.voices[0])
        await controller.selectVoiceOutput(selected)
        let accepted = await controller.saveVoiceSynthesisOptions(try .init(useSSML: true, quality: .high))
        XCTAssertTrue(accepted)
        FakeLog.shared.setKey("synthetic-pronunciation-key", name: selected.apiKeyIdentifier)
        return selected
    }

    func installAzureReadTransport(_ session: URLSession) {
        VoicePronunciationProbe.shared.install { call in
            // The existing probe owns the Read usage record; avoid a second
            // fixture record while still executing the actual HTTP contract.
            try await VoiceSynthesisUsage.$capture.withValue(nil) {
                try await Self.azurePhonemeAudio(
                    call.source, selection: call.selection, credential: { "synthetic-pronunciation-key" },
                    session: session)
            }
        }
    }

    func generateIPAVoice(_ source: VoiceOutputSourceSnapshot, session: URLSession) async {
        await controller.generateVoiceSource(source, options: .init(autoPlay: false, saveToRecordings: false)) {
            input, selection, credential in
            try await Self.azurePhonemeAudio(input, selection: selection, credential: credential, session: session)
        }
        let pending = await controller.voiceGenerationTask
        await pending?.value
    }

    static func azurePhonemeAudio(
        _ source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String, session: URLSession
    ) async throws -> Data {
        try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: selection.voice, options: selection.options
        ) {
            // The incumbent fake's key is fixed; append a synthetic region
            // only at this fake HTTP boundary, never in production.
            try await credential() + ":eastus"
        }
    }

    func ipaOperation(
        _ action: Int, source: VoiceOutputSourceSnapshot, destination: URL
    ) async throws -> Task<Void, Never> {
        if action == 0 {
            await controller.readVoiceSource(source)
            let task = await controller.readAloudState.task
            return try XCTUnwrap(task)
        }
        if action == 1 {
            await controller.generateVoiceSource(source, options: .init(autoPlay: false, saveToRecordings: false)) {
                input, selection, credential in
                try await PronunciationVoicePlatform.synthesizeVoiceOutput(
                    input, selection: selection, credential: credential)
            }
            let task = await controller.voiceGenerationTask
            return try XCTUnwrap(task)
        }
        await controller.exportVoiceSource(source, path: destination.path) { input, selection, credential in
            try await PronunciationVoicePlatform.synthesizeVoiceOutput(
                input, selection: selection, credential: credential)
        }
        let task = await controller.readAloudState.exportTask
        return try XCTUnwrap(task)
    }
}
