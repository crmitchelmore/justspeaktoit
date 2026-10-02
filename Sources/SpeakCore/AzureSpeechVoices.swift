import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider-returned voice names are authoritative for the resource's region,
/// including every MAI voice and locale it offers. `AzureMAIVoiceCatalog`
/// supplies the current MAI models when a listing omits them.
public struct AzureSpeechVoice: Decodable, Sendable, Equatable {
    public let shortName: String
    public let displayName: String
    public let locale: String
    public let gender: String
    public var id: String { AzureMAIVoiceCatalog.voiceIDPrefix + shortName }
    public var isMAI: Bool { AzureMAIVoiceCatalog.isMAIVoice(shortName) }
    /// MAI speakers such as Harper exist in many locales, so their names carry
    /// the locale as well as the model.
    public var name: String {
        guard let model = shortName.split(separator: ":").last, isMAI else { return displayName }
        return AzureMAIVoiceCatalog.displayName(speaker: displayName, locale: locale, model: String(model))
    }

    enum CodingKeys: String, CodingKey {
        case shortName = "ShortName", displayName = "DisplayName", locale = "Locale", gender = "Gender"
    }
}

/// A synthesis response that was not audio, with Azure's own diagnostic.
///
/// `detail` is Azure's response text with whitespace collapsed, capped at
/// `detailLimit` characters plus an ellipsis, and with an exact subscription-key
/// echo removed. It can still contain user content and is not safe for logging.
public struct AzureSpeechSynthesisError: LocalizedError, Sendable, Equatable {
    public static let detailLimit = 300
    public let statusCode: Int
    public let detail: String

    public init(statusCode: Int, body: Data, apiKey: String) {
        self.statusCode = statusCode
        var text = String(bytes: body, encoding: .utf8) ?? ""
        if !apiKey.isEmpty { text = text.replacingOccurrences(of: apiKey, with: "[redacted]") }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.detail = collapsed.count > Self.detailLimit ? String(collapsed.prefix(Self.detailLimit)) + "…" : collapsed
    }

    /// Whether Azure's text says the voice or model itself is unavailable, as
    /// opposed to a malformed request. Only that justifies access guidance.
    public var indicatesUnavailableVoice: Bool {
        guard statusCode == 400 || statusCode == 404 else { return false }
        let text = detail.lowercased()
        // Recognise a direct statement about the model, not unrelated words in
        // an SSML diagnostic such as "voice element has an unsupported attribute".
        // Ambiguous provider wording keeps the ordinary synthesis diagnostic.
        let name = #"(?:[a-z]{2,3}(?:-[a-z0-9]+)+:)?mai-voice-[a-z0-9.-]+"#
        let subject = #"(?:the )?(?:voice|model)(?: ["']?\#(name)["']?)?"#
        let unavailable = "(?:not supported|unsupported|not available|unavailable|not found|"
            + "does not exist|not allowed|not enabled)"
        let scope = #"(?:[.!?]|$| (?:in|for|on) (?:this |the |your )?(?:region|resource|subscription|account)\b)"#
        let patterns = [
            #"^\#(subject) (?:is )?\#(unavailable)\#(scope)"#,
            #"^unsupported (?:voice|model)(?: ["']?\#(name)["']?)?\#(scope)"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    public var errorDescription: String? {
        let status = AzureSpeechError.service(statusCode).errorDescription
            ?? "Azure Speech returned HTTP \(statusCode)."
        return detail.isEmpty ? status : "\(status) \(detail)"
    }
}

public struct AzureSpeechVoiceAPI: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func listVoices(credentials: String) async throws -> [AzureSpeechVoice] {
        let config = try AzureSpeechConfiguration(credentials: credentials)
        var request = URLRequest(url: config.voicesURL, timeoutInterval: 30)
        request.setValue(config.apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        let redirects = BatchTranscriptionJob.OriginBoundRedirects(origin: config.voicesURL)
        let (data, response) = try await session.data(for: request, delegate: redirects)
        guard let http = response as? HTTPURLResponse else { throw AzureSpeechError.invalidResponse }
        guard http.statusCode == 200 else { throw AzureSpeechError.service(http.statusCode) }
        return try JSONDecoder().decode([AzureSpeechVoice].self, from: data)
    }

    /// Synthesises one request and returns Azure's audio bytes.
    ///
    /// `Ocp-Apim-Subscription-Key` is a custom header URLSession keeps on a
    /// cross-origin hop, so redirects stay bound to the regional origin.
    public func synthesize(
        credentials: String, text: String, voice: String, format: String,
        speed: Double = 1, pitch: Double = 0, useSSML: Bool = false
    ) async throws -> Data {
        let request = try Self.synthesisRequest(
            credentials: credentials, text: text, voice: voice, format: format,
            speed: speed, pitch: pitch, useSSML: useSSML
        )
        guard let origin = request.url else { throw AzureSpeechError.invalidResponse }
        try Task.checkCancellation()
        let redirects = BatchTranscriptionJob.OriginBoundRedirects(origin: origin)
        let (data, response) = try await session.data(for: request, delegate: redirects)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AzureSpeechError.invalidResponse }
        guard http.statusCode == 200 else {
            // A rejected key or region keeps its credential guidance; any other
            // failure keeps Azure's own diagnostic.
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AzureSpeechError.service(http.statusCode)
            }
            throw AzureSpeechSynthesisError(
                statusCode: http.statusCode, body: data,
                apiKey: request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") ?? ""
            )
        }
        guard !data.isEmpty else { throw AzureSpeechError.invalidResponse }
        return data
    }

    public static func synthesisRequest(
        credentials: String, text: String, voice: String, format: String,
        speed: Double = 1, pitch: Double = 0, useSSML: Bool = false
    ) throws -> URLRequest {
        let config = try AzureSpeechConfiguration(credentials: credentials)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AzureSpeechError.emptyInput
        }
        let name = AzureMAIVoiceCatalog.shortName(forVoiceID: voice)
        guard !name.isEmpty else { throw AzureSpeechError.unsupportedModel }
        let isMAI = AzureMAIVoiceCatalog.isMAIVoice(name)
        if isMAI, speed != 1 || pitch != 0 {
            throw AzureSpeechError.configuration("Use normal speed and pitch for MAI voices.")
        }
        let locale = name.split(separator: "-").prefix(2).joined(separator: "-")
        let content: String
        if useSSML && text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<speak") {
            content = text
        } else {
            let spoken = useSSML ? text : escapeXML(text)
            let rate = Int((min(max(speed, 0.5), 2) - 1) * 100)
            let semitones = Int(min(max(pitch, -12), 12))
            let rateValue = rate >= 0 ? "+\(rate)%" : "\(rate)%"
            let pitchValue = semitones >= 0 ? "+\(semitones)st" : "\(semitones)st"
            // MAI voices do not inherit every conventional neural-voice SSML
            // control. Send plain speech at default settings for compatibility.
            let body = isMAI ? spoken
                : "<prosody rate='\(rateValue)' pitch='\(pitchValue)'>\(spoken)</prosody>"
            content = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
                + "xml:lang='\(escapeXML(locale))'><voice name='\(escapeXML(name))'>\(body)</voice></speak>"
        }
        var request = URLRequest(url: config.synthesisURL, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue(format, forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("JustSpeakToIt", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(content.utf8)
        return request
    }

    private static func escapeXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
