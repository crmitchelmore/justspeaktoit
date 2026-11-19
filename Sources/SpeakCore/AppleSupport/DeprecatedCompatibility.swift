import Foundation

// MARK: - Deprecated compatibility shims (issue #680)
//
// PR #628 removed exported types as dead in-repository code, which was a
// source-breaking change for external SwiftPM consumers of SpeakCore.
//
// Decision per issue #680:
// - `SpeakErrorMessage` is restored verbatim below as a deprecated shim and
//   may be removed only in a declared major version. Do not adopt it in new
//   code.
// - `PermissionStatus` is NOT restored: its name collides with the app's
//   live `PermissionStatus` (the collision #628 fixed), and the module also
//   exports a `SpeakApp` type, so the clash cannot be qualified away. Its
//   removal is a documented break that shipped with #628 in the v2.4x line;
//   migrate to the owning platform permission APIs
//   (`AVCaptureDevice.authorizationStatus`, `SFSpeechRecognizer
//   .authorizationStatus`). The api-compatibility CI gate now prevents this
//   class of undeclared removal from recurring.

// MARK: - User-Facing Error Messages

/// Provides actionable error messages for common failure scenarios.
@available(*, deprecated, message: "Use the owning subsystem's LocalizedError texts; see issue #680.")
public enum SpeakErrorMessage {

    /// Returns a user-friendly message with actionable steps.
    public static func userMessage(for error: Error) -> (title: String, message: String, action: String?) {
        // swiftlint:disable:previous large_tuple
        // Check for common error types
        if let urlError = error as? URLError {
            return handleURLError(urlError)
        }

        if let secureError = error as? SecureStorageError {
            return handleSecureStorageError(secureError)
        }

        // Check error domain/code for system errors
        let nsError = error as NSError

        // Speech recognition errors
        if nsError.domain == "kAFAssistantErrorDomain" {
            return handleSpeechError(nsError)
        }

        // Audio session errors
        if nsError.domain == NSOSStatusErrorDomain {
            return handleAudioError(nsError)
        }

        // Default
        return (
            title: "Something went wrong",
            message: error.localizedDescription,
            action: nil
        )
    }

    // swiftlint:disable:next large_tuple
    private static func handleURLError(_ error: URLError) -> (String, String, String?) {
        switch error.code {
        case .notConnectedToInternet:
            return (
                "No Internet Connection",
                "Transcription with cloud providers requires an internet connection.",
                "Check your Wi-Fi or cellular connection, or switch to on-device Apple Speech."
            )
        case .timedOut:
            return (
                "Connection Timed Out",
                "The transcription service took too long to respond.",
                "Check your connection and try again."
            )
        case .cannotFindHost, .cannotConnectToHost:
            return (
                "Service Unavailable",
                "Could not connect to the transcription service.",
                "The service may be down. Try again later or switch providers."
            )
        case .secureConnectionFailed:
            return (
                "Secure Connection Failed",
                "Could not establish a secure connection.",
                "Check your network settings or try a different network."
            )
        default:
            return (
                "Network Error",
                error.localizedDescription,
                "Check your internet connection and try again."
            )
        }
    }

    // swiftlint:disable:next large_tuple
    private static func handleSecureStorageError(_ error: SecureStorageError) -> (String, String, String?) {
        switch error {
        case .permissionDenied:
            return (
                "Keychain Access Denied",
                "Unable to access stored API keys.",
                "Go to Settings → Privacy & Security → Keychain and ensure Speak has access."
            )
        case .valueNotFound:
            return (
                "API Key Missing",
                "No API key found for this service.",
                "Add your API key in Settings → API Keys."
            )
        case .unexpectedStatus:
            return (
                "Keychain Error",
                "An unexpected error occurred accessing secure storage.",
                "Try restarting the app. If the problem persists, re-enter your API keys."
            )
        default:
            return (
                "Keychain Error",
                error.localizedDescription,
                nil
            )
        }
    }

    // swiftlint:disable:next large_tuple
    private static func handleSpeechError(_ error: NSError) -> (String, String, String?) {
        switch error.code {
        case 1: // Speech not available
            return (
                "Speech Recognition Unavailable",
                "Speech recognition is not available on this device.",
                "Ensure your device supports speech recognition and you have "
                    + "an internet connection for first-time setup."
            )
        case 4: // Speech recognition denied
            return (
                "Speech Permission Required",
                "Speak needs permission to use speech recognition.",
                "Go to Settings → Privacy & Security → Speech Recognition and enable for Speak."
            )
        case 203: // Recognition request cancelled
            return (
                "Transcription Interrupted",
                "The transcription was interrupted.",
                "This can happen during calls or when switching apps. Try starting again."
            )
        default:
            return (
                "Speech Recognition Error",
                error.localizedDescription,
                nil
            )
        }
    }

    // swiftlint:disable:next large_tuple
    private static func handleAudioError(_ error: NSError) -> (String, String, String?) {
        (
            "Audio Error",
            "Could not access the microphone.",
            "Go to Settings → Privacy & Security → Microphone and ensure Speak has access."
        )
    }
}
