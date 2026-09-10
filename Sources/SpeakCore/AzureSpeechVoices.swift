import Foundation

/// Provider-returned voice names are authoritative for the resource's region.
/// This includes MAI-Voice-2 and Flash without guessing regional availability.
public struct AzureSpeechVoice: Decodable, Sendable, Equatable {
    public let shortName: String
    public let displayName: String
    public let locale: String
    public let gender: String
    public var id: String { "azure/\(shortName)" }
    public var isMAI: Bool { shortName.contains(":MAI-Voice-") }
    public var name: String {
        guard let model = shortName.split(separator: ":").last, isMAI else { return displayName }
        return "\(displayName) (\(model))"
    }

    enum CodingKeys: String, CodingKey {
        case shortName = "ShortName", displayName = "DisplayName", locale = "Locale", gender = "Gender"
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

    public static func synthesisRequest(
        credentials: String, text: String, voice: String, format: String,
        speed: Double = 1, pitch: Double = 0, useSSML: Bool = false
    ) throws -> URLRequest {
        let config = try AzureSpeechConfiguration(credentials: credentials)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AzureSpeechError.emptyInput
        }
        let name = voice.hasPrefix("azure/") ? String(voice.dropFirst(6)) : voice
        guard !name.isEmpty else { throw AzureSpeechError.unsupportedModel }
        if name.contains(":MAI-Voice-"), speed != 1 || pitch != 0 {
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
            let body = name.contains(":MAI-Voice-") ? spoken
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
