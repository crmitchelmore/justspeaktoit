import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

final class OpenRouterTTSRoutingTests: XCTestCase {
    func testProviderSharesExistingCredentialAndHasNoInventedPricingOrVoices() {
        XCTAssertEqual(TTSProvider.openrouter.apiKeyIdentifier, "openrouter.apiKey")
        XCTAssertTrue(TTSProvider.openrouter.sharesTranscriptionCredential)
        XCTAssertNil(TTSProvider.openrouter.estimatedCost(characterCount: 100, quality: .high))
        XCTAssertTrue(VoiceCatalog.voices(for: .openrouter).isEmpty)
    }

    func testDynamicSelectionRemainsInPickerWithoutCatalogueEntry() {
        let selection = OpenRouterSpeechSelection(modelID: "vendor/new-speech", voice: "custom/voice")
        let voices = VoiceCatalog.includingSelection(selection.id, in: VoiceCatalog.systemVoices)
        XCTAssertEqual(voices.last?.id, selection.id)
        XCTAssertEqual(voices.last?.provider, .openrouter)
        XCTAssertEqual(TTSProvider.from(voiceID: selection.id), .openrouter)
        XCTAssertEqual(VoiceCatalog.includingSelection(selection.id, in: voices), voices)
    }

    @MainActor
    func testDefaultAndExplicitSelectionRouteWithoutFallback() async throws {
        let savedHistory = UserDefaults.standard.data(forKey: "ttsUsageHistory")
        defer { UserDefaults.standard.set(savedHistory, forKey: "ttsUsageHistory") }
        let selection = OpenRouterSpeechSelection(modelID: "vendor/new-speech", voice: "new-voice")
        let client = OpenRouterTTSRoutingStub()
        let (manager, settings) = makeManager(client: client)
        settings.defaultTTSVoice = selection.id
        let first = Task { try await manager.synthesize(text: "Hello") }
        await client.waitForRequest()
        let output = try makeOutput(voice: selection.id)
        await client.complete(with: output)
        let result = try await first.value
        XCTAssertEqual(result.voice, selection.id)
        XCTAssertEqual(settings.defaultTTSVoice, selection.id)
        XCTAssertEqual(manager.usageHistory.last?.cost, Decimal(string: "0.002"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.audioURL.path))

        let override = OpenRouterSpeechSelection(modelID: "vendor/next", voice: nil)
        let second = Task { try await manager.synthesize(text: "Again", voice: override.id) }
        await client.waitForRequest()
        let replacement = try makeOutput(voice: override.id)
        await client.complete(with: replacement)
        _ = try await second.value
        XCTAssertEqual(settings.defaultTTSVoice, selection.id)
        XCTAssertEqual(manager.lastResult?.voice, override.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.audioURL.path))
        let requestedVoice = await client.lastRequestedVoice()
        XCTAssertEqual(requestedVoice, override.id)
    }

    @MainActor
    func testStopDiscardsLateResultAndDeletesOwnedFile() async throws {
        let client = OpenRouterTTSRoutingStub()
        let (manager, settings) = makeManager(client: client)
        let selection = OpenRouterSpeechSelection(modelID: "vendor/speech")
        settings.defaultTTSVoice = selection.id
        let previousUsageCount = manager.usageHistory.count
        let task = Task { try await manager.synthesize(text: "Hello") }
        await client.waitForRequest()
        manager.stop()
        let output = try makeOutput(voice: selection.id)
        await client.complete(with: output)
        do {
            _ = try await task.value
            XCTFail("Stopped synthesis must not publish a late result")
        } catch is CancellationError {
            XCTAssertNil(manager.lastResult)
            XCTAssertNil(manager.lastError)
            XCTAssertEqual(manager.usageHistory.count, previousUsageCount)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.audioURL.path))
            XCTAssertFalse(manager.isSynthesizing)
        }
    }

    @MainActor
    func testUnavailableProviderKeepsSavedSelectionAndReportsError() async {
        let (manager, settings) = makeManager(client: nil)
        let selection = OpenRouterSpeechSelection(modelID: "vendor/retired")
        settings.defaultTTSVoice = selection.id
        do {
            _ = try await manager.synthesize(text: "Hello")
            XCTFail("Missing provider must fail")
        } catch {
            guard case .providerNotAvailable(.openrouter)? = manager.lastError else {
                return XCTFail("Expected explicit OpenRouter error")
            }
            XCTAssertEqual(settings.defaultTTSVoice, selection.id)
        }
    }

    func testProviderErrorsDoNotExposeRawDetails() {
        let secretError = NSError(domain: "private-token-and-transcript", code: 7)
        XCTAssertFalse(OpenRouterTTSClient.ttsError(for: secretError).localizedDescription.contains("private-token"))
        for status in [401, 403] {
            guard case .apiKeyMissing(.openrouter) = OpenRouterTTSClient.ttsError(
                for: OpenRouterAudioError.httpStatus(status)
            ) else { return XCTFail("Authentication errors should identify the OpenRouter key") }
        }
        XCTAssertTrue(OpenRouterTTSClient.ttsError(for: OpenRouterAudioError.httpStatus(404))
            .localizedDescription.contains("Choose another model"))
    }

    @MainActor
    func testLocalPlaybackSpeedIsFiniteAndWithinPlayerRange() {
        XCTAssertEqual(TextToSpeechManager.openRouterPlaybackRate(speed: 1.5), 1.5)
        XCTAssertEqual(TextToSpeechManager.openRouterPlaybackRate(speed: .nan), 1)
        XCTAssertEqual(TextToSpeechManager.openRouterPlaybackRate(speed: .infinity), 1)
        XCTAssertEqual(TextToSpeechManager.openRouterPlaybackRate(speed: 4), 2)
        XCTAssertEqual(TextToSpeechManager.openRouterPlaybackRate(speed: 0), 0.5)
    }

    @MainActor
    func testStopDuringSavingPreventsLateAutoplay() async throws {
        let savedHistory = UserDefaults.standard.data(forKey: "ttsUsageHistory")
        defer { UserDefaults.standard.set(savedHistory, forKey: "ttsUsageHistory") }
        let client = OpenRouterTTSRoutingStub()
        let saveGate = OpenRouterTTSSaveGate()
        let (manager, settings) = makeManager(client: client, recordingSaver: { _ in await saveGate.pause() })
        settings.ttsAutoPlay = true
        settings.ttsSaveToDirectory = true
        let selection = OpenRouterSpeechSelection(modelID: "vendor/speech")
        settings.defaultTTSVoice = selection.id
        let task = Task { try await manager.synthesize(text: "Hello") }
        await client.waitForRequest()
        let output = try makeOutput(voice: selection.id)
        await client.complete(with: output)
        await saveGate.waitUntilPaused()
        manager.stop()
        XCTAssertFalse(manager.isSynthesizing)
        await saveGate.release()
        do {
            _ = try await task.value
            XCTFail("Stop must prevent autoplay after saving finishes")
        } catch is CancellationError {
            XCTAssertFalse(manager.isPlaying)
            XCTAssertNil(manager.lastError)
            XCTAssertEqual(manager.lastResult?.audioURL, output.audioURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.audioURL.path))
        }
    }

    @MainActor
    private func makeManager(
        client: TextToSpeechClient?, recordingSaver: (@MainActor (TTSResult) async throws -> Void)? = nil
    ) -> (TextToSpeechManager, AppSettings) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "OpenRouterTTS-\(UUID().uuidString)")!)
        settings.ttsAutoPlay = false
        settings.ttsSaveToDirectory = false
        let storage = SecureAppStorage(permissionsManager: PermissionsManager(), appSettings: settings)
        let clients: [TTSProvider: TextToSpeechClient] = client.map { [.openrouter: $0] } ?? [:]
        let manager = TextToSpeechManager(
            appSettings: settings, secureStorage: storage, clients: clients, recordingSaver: recordingSaver
        )
        return (manager, settings)
    }

    private func makeOutput(voice: String) throws -> TTSResult {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-test-\(UUID()).mp3")
        try Data([1, 2, 3]).write(to: url)
        return TTSResult(
            audioURL: url, provider: .openrouter, voice: voice,
            duration: 1, characterCount: 5, cost: Decimal(string: "0.002")
        )
    }
}

private actor OpenRouterTTSRoutingStub: TextToSpeechClient {
    let provider: TTSProvider = .openrouter
    private var requestedVoice: String?
    private var completion: CheckedContinuation<TTSResult, Never>?
    private var startObserver: CheckedContinuation<Void, Never>?

    func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
        requestedVoice = voice
        return await withCheckedContinuation { continuation in
            completion = continuation
            startObserver?.resume()
            startObserver = nil
        }
    }

    func waitForRequest() async {
        if completion != nil { return }
        await withCheckedContinuation { startObserver = $0 }
    }

    func complete(with result: TTSResult) {
        completion?.resume(returning: result)
        completion = nil
    }

    func lastRequestedVoice() -> String? { requestedVoice }
    func listVoices() async throws -> [TTSVoice] { [] }
    func validateAPIKey(_ key: String) async -> APIKeyValidationResult { .success(message: "Valid") }
}

private actor OpenRouterTTSSaveGate {
    private var pendingSave: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            pendingSave = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilPaused() async {
        if pendingSave != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        pendingSave?.resume()
        pendingSave = nil
    }
}
