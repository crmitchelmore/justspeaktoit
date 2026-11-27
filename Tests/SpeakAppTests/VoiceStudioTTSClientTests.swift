import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest

@testable import SpeakApp

final class VoiceStudioTTSClientTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var session: URLSession!
  private var keychainService: String!
  private var storageToClean: SecureAppStorage?
  private var identifierToClean: String?

  private struct TestContext {
    let settings: AppSettings
    let storage: SecureAppStorage
    let manager: TextToSpeechManager
  }

  override func setUp() async throws {
    suiteName = "VoiceStudioTTSClientTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    session = StubURLProtocol.makeSession()
    keychainService = "com.justspeaktoit.tests.voice-studio.\(UUID().uuidString)"
  }

  override func tearDown() async throws {
    if let storageToClean, let identifierToClean {
      try? await storageToClean.removeSecret(identifier: identifierToClean)
    }
    storageToClean = nil
    session.invalidateAndCancel()
    StubURLProtocol.reset()
    defaults.removePersistentDomain(forName: suiteName)
  }

  @MainActor
  private func makeContext() -> TestContext {
    let settings = AppSettings(defaults: defaults)
    settings.ttsAutoPlay = false
    settings.ttsSaveToDirectory = false
    let storage = SecureAppStorage(
      permissionsManager: PermissionsManager(),
      appSettings: settings,
      keychainService: keychainService
    )
    let client = VoiceStudioTTSClient(appSettings: settings, secureStorage: storage, session: session)
    let manager = TextToSpeechManager(
      appSettings: settings,
      secureStorage: storage,
      clients: [.voiceStudio: client, .system: SystemTTSClient()],
      defaults: defaults
    )
    return TestContext(settings: settings, storage: storage, manager: manager)
  }

  @MainActor
  func testDisabledStudioMakesNoRequestsAndFailsExplicitlyWithoutFallback() async throws {
    let context = makeContext()
    StubURLProtocol.handler = { request in
      XCTFail("Disabled voice studio should never hit network: \(request.url?.absoluteString ?? "?")")
      return .fail(URLError(.badURL))
    }

    let accountVoices = await context.manager.accountListedVoices()
    XCTAssertFalse(accountVoices.contains { $0.provider == .voiceStudio })

    let disabledMessage = try await synthesisFailureMessage(
      in: context,
      voice: "studio/voicebox/alice",
      text: "Hello world."
    )
    XCTAssertEqual(disabledMessage, VoiceStudioError.disabled.localizedDescription)
    XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
  }

  @MainActor
  func testEnabledVoiceboxDiscoversAndSpeaksWithoutCloudConsent() async throws {
    let context = makeContext()
    context.settings.voiceStudioEnabled = true
    context.settings.voiceStudioKind = .voicebox

    var consentPromptCalled = false
    context.manager.requireCloudSharingConsent = { _ in
      consentPromptCalled = true
      throw TTSError.synthesisFailure("Local studio must never require cloud consent")
    }

    let wavPayload = try Self.makePCM16MonoWAV(sampleRate: 24_000, frames: 960)
    StubURLProtocol.handler = { request in
      let url = try XCTUnwrap(request.url)
      if url.path == "/profiles", request.httpMethod == "GET" {
        let data = try JSONSerialization.data(withJSONObject: [
          ["id": "alice-1", "name": "Alice", "language": "en"]
        ])
        let http = try XCTUnwrap(HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        ))
        return .respond(http, data)
      }
      if url.path == "/generate", request.httpMethod == "POST" {
        let http = try XCTUnwrap(HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"]
        ))
        return .respond(http, wavPayload)
      }
      XCTFail("Unexpected request: \(url.path)")
      return .fail(URLError(.badURL))
    }

    let listed = await context.manager.accountListedVoices()
    let studioVoice = try XCTUnwrap(listed.first { $0.id == "studio/voicebox/alice-1" })
    XCTAssertEqual(studioVoice.provider, .voiceStudio)

    let result = try await context.manager.synthesize(text: "Local read aloud test.", voice: studioVoice.id)
    defer { try? FileManager.default.removeItem(at: result.audioURL) }
    XCTAssertFalse(consentPromptCalled)
    XCTAssertEqual(result.provider, .voiceStudio)
    XCTAssertEqual(result.voice, studioVoice.id)
    XCTAssertNil(result.cost)
    XCTAssertGreaterThan(result.duration, 0)
  }

  @MainActor
  func testGPTSoVITSSynthesisStoppedError() async throws {
    let context = makeContext()
    context.settings.voiceStudioEnabled = true
    context.settings.voiceStudioKind = .gptSoVITS
    context.settings.voiceStudioGPTSoVITSReferenceAudioPath = "/tmp/sample.wav"
    context.settings.voiceStudioGPTSoVITSReferencePromptText = "Sample reference transcript."
    context.settings.voiceStudioGPTSoVITSPromptLanguage = "en"
    context.settings.voiceStudioGPTSoVITSTextLanguage = "en"

    StubURLProtocol.handler = { _ in .fail(URLError(.cannotConnectToHost)) }
    let stoppedMessage = try await synthesisFailureMessage(
      in: context,
      voice: "studio/gpt-sovits/reference",
      text: "Check stopped error."
    )
    XCTAssertTrue(stoppedMessage.contains("GPT-SoVITS isn't running"))
  }

  @MainActor
  func testRemoteKeychainSecurityRejectsCleartextAndRequiresAPIKeyForHTTPS() async throws {
    let context = makeContext()
    context.settings.voiceStudioEnabled = true
    context.settings.voiceStudioKind = .voiceStudio
    context.settings.voiceStudioBaseURL = "http://remote-voice.example.com:8000"
    StubURLProtocol.resetRecordedRequests()
    let cleartextMessage = try await synthesisFailureMessage(
      in: context,
      voice: "studio/voicestudio/v1",
      text: "Blocked cleartext"
    )
    XCTAssertEqual(
      cleartextMessage,
      VoiceStudioError.cleartextNonLoopbackDisallowed(host: "remote-voice.example.com").localizedDescription
    )
    XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)

    context.settings.voiceStudioBaseURL = "https://remote-voice.example.com"
    let remoteKeyMessage = try await synthesisFailureMessage(
      in: context,
      voice: "studio/voicestudio/v1",
      text: "Missing key"
    )
    XCTAssertEqual(
      remoteKeyMessage,
      VoiceStudioError.remoteHTTPSRequiresAPIKey(host: "remote-voice.example.com").localizedDescription
    )
    XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)

    storageToClean = context.storage
    let token = "studio-remote-secret-\(UUID().uuidString)"
    let identifier = try context.settings.voiceStudioConfiguration.apiKeyCredentialIdentifier
    identifierToClean = identifier
    try await context.storage.storeSecret(token, identifier: identifier)
    let wavPayload = try Self.makePCM16MonoWAV(sampleRate: 24_000, frames: 960)
    StubURLProtocol.handler = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
      let http = try XCTUnwrap(HTTPURLResponse(
        url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"]
      ))
      return .respond(http, wavPayload)
    }

    let remoteResult = try await context.manager.synthesize(
      text: "Authenticated HTTPS.",
      voice: "studio/voicestudio/v1"
    )
    defer { try? FileManager.default.removeItem(at: remoteResult.audioURL) }
    XCTAssertEqual(remoteResult.provider, .voiceStudio)
  }

  @MainActor
  func testAppSettingsConfigurationRejectsCleartextRemoteURLAndRoundTripsFields() throws {
    let context = makeContext()
    let configuration = AppSettingsConfiguration(settings: context.settings, hasAPIKey: { _ in false })

    let badReport = configuration.validate(changes: [
      VoiceStudioPreference.baseURLKey: .string("http://untrusted.example.com:8000")
    ])
    XCTAssertEqual(badReport.errors.map(\.path), ["settings.\(VoiceStudioPreference.baseURLKey)"])

    let goodReport = configuration.validate(changes: [
      VoiceStudioPreference.enabledKey: .bool(true),
      VoiceStudioPreference.kindKey: .string(VoiceStudioKind.gptSoVITS.rawValue),
      VoiceStudioPreference.baseURLKey: .string("http://127.0.0.1:9880"),
      VoiceStudioPreference.gptSoVITSReferenceAudioPathKey: .string("/tmp/ref.wav"),
      VoiceStudioPreference.gptSoVITSReferencePromptTextKey: .string("Prompt words"),
      VoiceStudioPreference.gptSoVITSReferencePromptLanguageKey: .string("ja"),
      VoiceStudioPreference.gptSoVITSTextLanguageKey: .string("en")
    ])
    XCTAssertTrue(goodReport.errors.isEmpty)
    try configuration.apply(goodReport)

    XCTAssertTrue(context.settings.voiceStudioEnabled)
    XCTAssertEqual(context.settings.voiceStudioKind, .gptSoVITS)
    XCTAssertEqual(context.settings.voiceStudioBaseURL, "http://127.0.0.1:9880")
    XCTAssertEqual(context.settings.voiceStudioGPTSoVITSReferenceAudioPath, "/tmp/ref.wav")
    XCTAssertEqual(context.settings.voiceStudioGPTSoVITSReferencePromptText, "Prompt words")
    XCTAssertEqual(context.settings.voiceStudioGPTSoVITSPromptLanguage, "ja")
    XCTAssertEqual(context.settings.voiceStudioGPTSoVITSTextLanguage, "en")
  }

  @MainActor
  private func synthesisFailureMessage(
    in context: TestContext,
    voice: String,
    text: String
  ) async throws -> String {
    do {
      _ = try await context.manager.synthesize(text: text, voice: voice)
      XCTFail("Expected TTSError.synthesisFailure")
      throw TTSError.synthesisFailure("")
    } catch let error as TTSError {
      guard case .synthesisFailure(let message) = error else {
        throw error
      }
      return message
    }
  }

  private static func makePCM16MonoWAV(sampleRate: Int, frames: Int) throws -> Data {
    var pcm = Data(capacity: frames * 2)
    for index in 0..<frames {
      let sample = Int16(sin(Double(index) * 0.25) * 8_000.0)
      var little = UInt16(bitPattern: sample).littleEndian
      withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
    }
    return try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16))
  }
}
