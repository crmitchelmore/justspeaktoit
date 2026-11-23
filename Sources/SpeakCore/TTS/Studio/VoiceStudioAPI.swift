import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct VoiceStudioRequestContext {
    let kind: VoiceStudioKind
    let endpoint: ValidatedVoiceStudioEndpoint
    let apiKey: String?
    let session: URLSession
}

struct VoiceStudioTransferBudget {
    let limit: Int
    let deadline: Duration
}

/// Portable HTTP client for Voicebox, VoiceStudio, and GPT-SoVITS desktop voice studios.
public enum VoiceStudioAPI {
    public static let maxMetadataBytes = 1_048_576
    public static let maxAudioBytes = 64 * 1024 * 1024
    public static let maxVoices = 512
    public static let maxInputCharacters = 2_000
    public static let probeTimeout: Duration = .seconds(15)
    public static let synthesisTimeout: Duration = .seconds(180)

    static let metadataBudget = VoiceStudioTransferBudget(limit: maxMetadataBytes, deadline: probeTimeout)
    static let audioBudget = VoiceStudioTransferBudget(limit: maxAudioBytes, deadline: synthesisTimeout)
    static let pushBudget = VoiceStudioTransferBudget(limit: maxMetadataBytes, deadline: synthesisTimeout)

    /// Probes the studio server and returns version / voice-count / configuration status.
    public static func testConnection(
        configuration: VoiceStudioConfiguration,
        apiKey: String?,
        session: URLSession = .shared
    ) async throws -> VoiceStudioConnectionResult {
        try Task.checkCancellation()
        let endpoint = try VoiceStudioEndpointPolicy.validate(
            baseURLString: configuration.resolvedBaseURLString,
            apiKey: apiKey
        )
        let context = VoiceStudioRequestContext(
            kind: configuration.kind,
            endpoint: endpoint,
            apiKey: apiKey,
            session: session
        )

        switch configuration.kind {
        case .voicebox:
            return try await testVoiceboxConnection(context: context)
        case .voiceStudio:
            return try await testVoiceStudioConnection(context: context)
        case .gptSoVITS:
            return try await testGPTSoVITSConnection(configuration: configuration, context: context)
        }
    }

    /// Discovers voices exposed by the studio (or returns configured static voices for GPT-SoVITS).
    public static func listVoices(
        configuration: VoiceStudioConfiguration,
        apiKey: String?,
        session: URLSession = .shared
    ) async throws -> VoiceStudioVoiceInventory {
        try Task.checkCancellation()
        let endpoint = try VoiceStudioEndpointPolicy.validate(
            baseURLString: configuration.resolvedBaseURLString,
            apiKey: apiKey
        )
        let context = VoiceStudioRequestContext(
            kind: configuration.kind,
            endpoint: endpoint,
            apiKey: apiKey,
            session: session
        )

        switch configuration.kind {
        case .voicebox:
            let voices = try await fetchVoiceboxProfiles(context: context)
            return VoiceStudioVoiceInventory(
                kind: .voicebox,
                baseURL: endpoint.sanitizedURLString,
                voices: voices
            )
        case .voiceStudio:
            let voices = try await fetchVoiceStudioVoices(context: context)
            return VoiceStudioVoiceInventory(
                kind: .voiceStudio,
                baseURL: endpoint.sanitizedURLString,
                voices: voices
            )
        case .gptSoVITS:
            return VoiceStudioVoiceInventory(
                kind: .gptSoVITS,
                baseURL: endpoint.sanitizedURLString,
                voices: configuration.configuredStaticVoices()
            )
        }
    }

    /// Synthesizes one text segment through the configured studio backend and returns canonical WAV.
    public static func synthesize(
        text: String,
        voice: VoiceStudioVoice,
        configuration: VoiceStudioConfiguration,
        apiKey: String?,
        language: String? = nil,
        session: URLSession = .shared
    ) async throws -> VoiceStudioWAV.NormalizedAudio {
        try Task.checkCancellation()
        guard voice.studioKind == configuration.kind else {
            throw VoiceStudioError.unsupportedCapability(
                kind: configuration.kind,
                capability: "voice '\(voice.name)'"
            )
        }
        let endpoint = try VoiceStudioEndpointPolicy.validate(
            baseURLString: configuration.resolvedBaseURLString,
            apiKey: apiKey
        )
        let context = VoiceStudioRequestContext(
            kind: configuration.kind,
            endpoint: endpoint,
            apiKey: apiKey,
            session: session
        )

        switch configuration.kind {
        case .voicebox:
            return try await synthesizeVoicebox(
                text: text,
                voice: voice,
                language: language,
                context: context
            )
        case .voiceStudio:
            return try await synthesizeVoiceStudio(
                text: text,
                voice: voice,
                language: language,
                context: context
            )
        case .gptSoVITS:
            return try await synthesizeGPTSoVITS(
                text: text,
                configuration: configuration,
                language: language,
                context: context
            )
        }
    }

    /// Optional #1821 seam: pushes a confirmed local reference recording into Voicebox.
    public static func pushProfile(
        _ request: VoiceStudioProfilePushRequest,
        configuration: VoiceStudioConfiguration,
        apiKey: String?,
        session: URLSession = .shared
    ) async throws -> VoiceStudioVoice {
        try Task.checkCancellation()
        guard configuration.kind == .voicebox else {
            throw VoiceStudioError.unsupportedCapability(
                kind: configuration.kind,
                capability: "creating remote voice profiles"
            )
        }
        guard request.userConfirmedCopy else {
            throw VoiceStudioError.missingProfilePushConfirmation
        }
        let endpoint = try VoiceStudioEndpointPolicy.validate(
            baseURLString: configuration.resolvedBaseURLString,
            apiKey: apiKey
        )

        let trimmedName = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw VoiceStudioError.invalidResponse(kind: .voicebox, detail: "Profile name cannot be empty.")
        }
        guard !request.audioData.isEmpty else {
            throw VoiceStudioError.invalidResponse(kind: .voicebox, detail: "Profile audio clip cannot be empty.")
        }

        let boundary = "JSTI-VoiceStudio-\(UUID().uuidString)"
        let multipartBody = buildProfilePushBody(request: request, name: trimmedName, boundary: boundary)
        var urlRequest = makeRequest(
            url: endpoint.endpointURL(path: "profiles"),
            method: "POST",
            apiKey: apiKey,
            timeout: 60
        )
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = multipartBody

        let context = VoiceStudioRequestContext(
            kind: .voicebox,
            endpoint: endpoint,
            apiKey: apiKey,
            session: session
        )
        let response = try await performValidated(urlRequest, context: context, budget: pushBudget)
        return try decodeSingleProfile(response.body, kind: .voicebox)
    }
}
