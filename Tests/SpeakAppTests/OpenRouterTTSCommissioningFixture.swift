import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp
@testable import SpeakCore

@MainActor
final class OpenRouterTTSCommissioningFixture {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let settings: AppSettings
    let storage: SecureAppStorage
    let session: URLSession
    let client: OpenRouterTTSClient
    let selection = OpenRouterSpeechSelection(modelID: "vendor/speech", voice: "voice")

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "OpenRouterTTSCommissioning-\(UUID())"
        self.suite = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.defaults = defaults
        let settings = AppSettings(defaults: defaults)
        self.settings = settings
        settings.ttsAutoPlay = true
        settings.ttsSpeed = 1
        settings.ttsSaveToDirectory = false
        storage = SecureAppStorage(
            permissionsManager: PermissionsManager(), appSettings: settings,
            keychainService: "com.justspeaktoit.tests.progressive.\(UUID())"
        )
        let session = StubURLProtocol.makeSession()
        self.session = session
        client = OpenRouterTTSClient(
            api: OpenRouterAudioClient(
                apiKeyProvider: { "synthetic-test-key" }, session: session, temporaryDirectory: directory
            ),
            validationClient: OpenRouterAPIClient(apiKey: "synthetic-test-key", session: session)
        )
        settings.defaultTTSVoice = OpenRouterSpeechSelection(modelID: "vendor/speech", voice: "voice").id
    }

    func manager(
        option: OpenRouterProgressiveSpeechOption,
        save: (@MainActor (TTSResult) async throws -> Void)? = nil,
        operation: @escaping TextToSpeechManager.OpenRouterOperation
    ) -> TextToSpeechManager {
        TextToSpeechManager(
            appSettings: settings, secureStorage: storage, clients: [.openrouter: client],
            recordingSaver: save, defaults: defaults, progressiveSpeech: option, openRouterOperation: operation
        )
    }

    func result(name: String) throws -> TTSResult {
        let file = directory.appendingPathComponent(name + ".mp3")
        // Deliberately not playable: manager tests acknowledge fake completed
        // playback and must not accidentally open native output.
        try Data("synthetic unpublished artifact".utf8).write(to: file)
        return TTSResult(
            audioURL: file, provider: .openrouter, voice: selection.id,
            duration: 1, characterCount: 5, cost: nil, timestamp: Date(timeIntervalSince1970: 1)
        )
    }

    func cleanup() {
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func refuseRequest() {
        StubURLProtocol.handler = { request in
            .status(400, url: request.url!, headers: ["Content-Type": "audio/mpeg"])
        }
    }
}

@MainActor
final class OpenRouterTTSOperationGate {
    private let entered: XCTestExpectation
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation) { self.entered = entered }

    func wait() async {
        entered.fulfill()
        if !released { await withCheckedContinuation { waiter = $0 } }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
