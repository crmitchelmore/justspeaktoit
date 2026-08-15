import XCTest

@testable import SpeakCore

/// Coverage for the credential registry beyond header names: every provider
/// header the app sends, URL query items that carry a key, and nested payloads
/// such as crash-report contexts and HTTP breadcrumb data.
final class SensitiveValueRedactionTests: XCTestCase {

    // MARK: - Provider credential registry

    /// Every header name the app authenticates with. Taken from the provider
    /// clients: a new provider header must arrive here and in the registry
    /// together, or its key can leave the device in a crash report.
    private static let providerCredentialHeaders = [
        "Authorization",          // OpenAI, Deepgram, Soniox, Cartesia, Mistral, xAI, Rev.ai, Speechmatics, AssemblyAI
        "xi-api-key",             // ElevenLabs
        "x-gladia-key",           // Gladia
        "X-API-Key",              // Modulate
        "Ocp-Apim-Subscription-Key"  // Azure Speech
    ]

    func testIsSensitiveKey_everyProviderCredentialHeader_returnsTrue() {
        for header in Self.providerCredentialHeaders {
            XCTAssertTrue(
                SensitiveHeaderRedactor.isSensitiveKey(header),
                "\(header) carries a provider credential and must be in the registry"
            )
        }
    }

    func testFullyRedactSensitiveHeaders_everyProviderCredentialHeader_leaksNothing() {
        let apiKey = "abcdefghijklmnopqrstuvwxyz012345"
        for header in Self.providerCredentialHeaders {
            let result = SensitiveHeaderRedactor.fullyRedactSensitiveHeaders([header: apiKey])
            let redacted = result[header] ?? ""
            XCTAssertEqual(redacted, "[REDACTED]", "\(header) should be fully redacted")
            XCTAssertFalse(redacted.contains(apiKey.prefix(3)), "\(header) should leak no prefix")
        }
    }

    func testIsSensitiveKey_azureSubscriptionKey_caseInsensitive() {
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("Ocp-Apim-Subscription-Key"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("ocp-apim-subscription-key"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveKey("OCP-APIM-SUBSCRIPTION-KEY"))
    }

    // MARK: - Query item names

    func testIsSensitiveQueryItemName_credentialCarriers_returnTrue() {
        // AssemblyAI puts the key in `token`, Modulate in `api_key`.
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveQueryItemName("token"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveQueryItemName("api_key"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveQueryItemName("API_KEY"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveQueryItemName("access_token"))
        XCTAssertTrue(SensitiveHeaderRedactor.isSensitiveQueryItemName("key"))
    }

    func testIsSensitiveQueryItemName_plainParameters_returnFalse() {
        XCTAssertFalse(SensitiveHeaderRedactor.isSensitiveQueryItemName("model"))
        XCTAssertFalse(SensitiveHeaderRedactor.isSensitiveQueryItemName("sample_rate"))
        XCTAssertFalse(SensitiveHeaderRedactor.isSensitiveQueryItemName("encoding"))
    }

    // MARK: - redactSensitiveQueryString

    func testRedactSensitiveQueryString_redactsCredentialKeepsRest() {
        let apiKey = "abcdefghijklmnopqrstuvwxyz012345"
        let result = SensitiveHeaderRedactor.redactSensitiveQueryString(
            "sample_rate=16000&token=\(apiKey)&encoding=pcm_s16le"
        )

        XCTAssertEqual(result, "sample_rate=16000&token=[REDACTED]&encoding=pcm_s16le")
        XCTAssertFalse(result.contains(apiKey))
    }

    func testRedactSensitiveQueryString_noCredential_passesThrough() {
        let query = "model=nova-3&punctuate=true"
        XCTAssertEqual(SensitiveHeaderRedactor.redactSensitiveQueryString(query), query)
    }

    // MARK: - redactSensitiveQueryItems

    func testRedactSensitiveQueryItems_modulateStyleURL_redactsKey() {
        let apiKey = "abcdefghijklmnopqrstuvwxyz012345"
        let url = "https://www.modulate-developer-apis.com/transcribe?api_key=\(apiKey)&emotion_signal=false"

        let result = SensitiveHeaderRedactor.redactSensitiveQueryItems(in: url)

        XCTAssertEqual(
            result,
            "https://www.modulate-developer-apis.com/transcribe?api_key=[REDACTED]&emotion_signal=false"
        )
    }

    func testRedactSensitiveQueryItems_assemblyAIStyleURL_redactsToken() {
        let apiKey = "abcdefghijklmnopqrstuvwxyz012345"
        let url = "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&token=\(apiKey)"

        let result = SensitiveHeaderRedactor.redactSensitiveQueryItems(in: url)

        XCTAssertFalse(result.contains(apiKey), "Credential must not survive in the URL")
        XCTAssertTrue(result.contains("sample_rate=16000"), "Diagnostic parameters should survive")
    }

    func testRedactSensitiveQueryItems_noQueryString_returnsInputUnchanged() {
        let url = "https://api.openai.com/v1/audio/transcriptions"
        XCTAssertEqual(SensitiveHeaderRedactor.redactSensitiveQueryItems(in: url), url)
    }

    func testRedactSensitiveQueryItems_fragmentSurvives() {
        let result = SensitiveHeaderRedactor.redactSensitiveQueryItems(
            in: "https://example.com/path?token=abcdefghijklmnopqrstuvwxyz012345#section"
        )
        XCTAssertEqual(result, "https://example.com/path?token=[REDACTED]#section")
    }

    // MARK: - fullyRedactSensitiveValues

    func testFullyRedactSensitiveValues_nestedHeaderMap_isRedacted() {
        let apiKey = "abcdefghijklmnopqrstuvwxyz012345"
        let payload: [String: Any] = [
            "request": [
                "headers": [
                    "xi-api-key": apiKey,
                    "Content-Type": "application/json"
                ],
                "method": "POST"
            ]
        ]

        let result = SensitiveHeaderRedactor.fullyRedactSensitiveValues(in: payload)

        let request = result["request"] as? [String: Any]
        let headers = request?["headers"] as? [String: Any]
        XCTAssertEqual(headers?["xi-api-key"] as? String, "[REDACTED]")
        XCTAssertEqual(headers?["Content-Type"] as? String, "application/json")
        XCTAssertEqual(request?["method"] as? String, "POST")
    }

    func testFullyRedactSensitiveValues_urlValue_hasQueryCredentialRedacted() {
        let apiKey = "abcdefghijklmnopqrstuvwxyz012345"
        let payload: [String: Any] = [
            "url": "https://api.gladia.io/v2/live?api_key=\(apiKey)",
            "status_code": 500
        ]

        let result = SensitiveHeaderRedactor.fullyRedactSensitiveValues(in: payload)

        let url = result["url"] as? String ?? ""
        XCTAssertFalse(url.contains(apiKey), "Credential must not survive in a nested URL")
        XCTAssertTrue(url.contains("api.gladia.io"), "The endpoint stays useful for diagnosis")
        XCTAssertEqual(result["status_code"] as? Int, 500, "Non-string values pass through")
    }

    func testFullyRedactSensitiveValues_listOfHeaderMaps_isRedacted() {
        let apiKey = "abcdefghijklmnopqrstuvwxyz012345"
        let payload: [String: Any] = [
            "breadcrumbs": [
                ["data": ["Ocp-Apim-Subscription-Key": apiKey]]
            ]
        ]

        let result = SensitiveHeaderRedactor.fullyRedactSensitiveValues(in: payload)
        let serialized = String(describing: result)

        XCTAssertFalse(serialized.contains(apiKey), "Credentials in arrays must be redacted too")
    }

    func testFullyRedactSensitiveValues_credentialLikeValue_isRedacted() {
        // The value pattern catches a credential recorded under an unknown key.
        let apiKey = "sk-abcdefghijklmnopqrstuvwx1234567890"
        let result = SensitiveHeaderRedactor.fullyRedactSensitiveValues(in: ["note": apiKey])

        XCTAssertEqual(result["note"] as? String, "[REDACTED]")
    }
}
