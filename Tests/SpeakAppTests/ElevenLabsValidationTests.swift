import Foundation
import XCTest

@testable import SpeakApp

// MARK: - Mock URLSession

/// Intercepts URLSession data requests and returns configured stub responses.
private final class StubURLSession: URLSession, @unchecked Sendable {
  var responsesByPath: [String: Int] = [:]

  override func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let path = request.url?.lastPathComponent ?? ""
    let statusCode = responsesByPath[path] ?? 200
    let url = request.url ?? URL(string: "https://api.elevenlabs.io")!
    let response = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    return (Data(), response)
  }
}

// MARK: - ElevenLabsValidationTests

final class ElevenLabsValidationTests: XCTestCase {

  // Bootstrapped environment — provides a real SecureAppStorage without Keychain side effects.
  @MainActor
  private func makeClient(session: StubURLSession) -> ElevenLabsClient {
    let env = WireUp.bootstrap()
    return ElevenLabsClient(secureStorage: env.secureStorage, session: session)
  }

  /// A key valid for both TTS and Scribe returns `.success`.
  func testValidateAPIKey_fullScopeKey_returnsSuccess() async {
    let session = StubURLSession()
    session.responsesByPath["user"] = 200
    // 405 Method Not Allowed = authenticated but GET is unsupported; Scribe scope confirmed.
    session.responsesByPath["speech-to-text"] = 405

    let client = await makeClient(session: session)
    let result = await client.validateAPIKey("full-scope-key")

    guard case .success = result.outcome else {
      XCTFail("Expected .success for a full-scope key, got \(result.outcome)")
      return
    }
  }

  /// A TTS-only restricted key must return `.failure` — it cannot reach the Scribe endpoint.
  func testValidateAPIKey_ttsOnlyRestrictedKey_returnsFailure() async {
    let session = StubURLSession()
    session.responsesByPath["user"] = 200
    // 403 Forbidden = key lacks Speech-to-Text scope.
    session.responsesByPath["speech-to-text"] = 403

    let client = await makeClient(session: session)
    let result = await client.validateAPIKey("tts-only-restricted-key")

    guard case .failure = result.outcome else {
      XCTFail("Expected .failure for a TTS-only restricted key, got \(result.outcome)")
      return
    }
  }

  /// An invalid key (401 at /user) must return `.failure` without probing Scribe.
  func testValidateAPIKey_invalidKey_returnsFailure() async {
    let session = StubURLSession()
    session.responsesByPath["user"] = 401

    let client = await makeClient(session: session)
    let result = await client.validateAPIKey("invalid-key")

    guard case .failure = result.outcome else {
      XCTFail("Expected .failure for an invalid key, got \(result.outcome)")
      return
    }
  }
}
