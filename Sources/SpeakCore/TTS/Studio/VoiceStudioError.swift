import Foundation

/// Actionable, sanitized errors surfaced directly to the user without falling back to system/cloud TTS.
public enum VoiceStudioError: Error, LocalizedError, Equatable, Sendable {
    case disabled
    case invalidURL(detail: String)
    case cleartextNonLoopbackDisallowed(host: String)
    case remoteHTTPSRequiresAPIKey(host: String)
    case credentialsInURLDisallowed
    case crossOriginAudioURLDisallowed(origin: String)
    case studioNotRunning(kind: VoiceStudioKind, baseURL: String)
    case tlsError(kind: VoiceStudioKind, detail: String)
    case unauthorized(kind: VoiceStudioKind, statusCode: Int)
    case httpError(kind: VoiceStudioKind, statusCode: Int, detail: String)
    case invalidResponse(kind: VoiceStudioKind, detail: String)
    case missingGPTSoVITSConfiguration(detail: String)
    case missingProfilePushConfirmation
    case unsupportedCapability(kind: VoiceStudioKind, capability: String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Local voice studio is disabled in Settings."
        case .invalidURL(let detail):
            "Invalid voice studio URL: \(detail)"
        case .cleartextNonLoopbackDisallowed(let host):
            "Refusing unencrypted http:// connection to non-loopback host '\(host)'. "
                + "Use http:// only on loopback (127.0.0.1, localhost, ::1), or switch to https:// with an API key."
        case .remoteHTTPSRequiresAPIKey(let host):
            "Remote voice studio host '\(host)' over https:// requires a configured API key in secure storage."
        case .credentialsInURLDisallowed:
            "Voice studio URLs must not contain embedded usernames or passwords. Store the API key in Settings instead."
        case .crossOriginAudioURLDisallowed(let origin):
            "Refused generated audio URL from unexpected origin '\(origin)'."
        case .studioNotRunning(let kind, let baseURL):
            "\(kind.displayName) isn't running at \(baseURL). "
                + "Start \(kind.displayName) or verify the server URL in Settings."
        case .tlsError(let kind, let detail):
            "\(kind.displayName) TLS verification failed: \(detail)"
        case .unauthorized(let kind, let statusCode):
            "\(kind.displayName) rejected authentication (HTTP \(statusCode)). "
                + "Check your \(kind.displayName) API key in Settings."
        case .httpError(let kind, let statusCode, let detail):
            "\(kind.displayName) returned HTTP \(statusCode): \(detail)"
        case .invalidResponse(let kind, let detail):
            "\(kind.displayName) returned an unexpected response: \(detail)"
        case .missingGPTSoVITSConfiguration(let detail):
            detail
        case .missingProfilePushConfirmation:
            "Confirm copying your voice recording before pushing a profile to Voicebox."
        case .unsupportedCapability(let kind, let capability):
            "\(kind.displayName) does not support \(capability)."
        }
    }
}
