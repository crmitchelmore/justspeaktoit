import Foundation

// MARK: - OpenClaw Error

/// Errors returned by the OpenClaw gateway client.
public enum OpenClawError: LocalizedError {
    case encodingFailed
    case serverError(String)
    case notConnected
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode request"
        case .serverError(let message):
            return "Server error: \(message)"
        case .notConnected:
            return "Not connected to OpenClaw gateway"
        case .invalidResponse:
            return "Invalid response from server"
        }
    }
}
