import Foundation
import os.log

// MARK: - Unified Logging

/// Provides unified logging across SpeakCore and related modules.
/// Uses OSLog for system-integrated logging with privacy controls.
public enum SpeakLogger {
    
    // MARK: - Subsystems
    
    private static let subsystem = "com.speak"
    
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let keychain = Logger(subsystem: subsystem, category: "keychain")
    public static let activity = Logger(subsystem: subsystem, category: "activity")
    public static let transport = Logger(subsystem: subsystem, category: "transport")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let general = Logger(subsystem: subsystem, category: "general")
    
    // MARK: - Debug Mode
    
    /// When true, logs include more detailed information.
    /// Should be controlled via Settings toggle.
    public static var isDebugMode: Bool {
        get { UserDefaults.standard.bool(forKey: "speakDebugLogging") }
        set { UserDefaults.standard.set(newValue, forKey: "speakDebugLogging") }
    }
    
    // MARK: - Convenience Methods
    
    /// Logs an error with context.
    public static func logError(_ error: Error, context: String, logger: Logger = general) {
        logger.error("[\(context, privacy: .public)] \(error.localizedDescription, privacy: .public)")
        if isDebugMode {
            logger.debug("[\(context, privacy: .public)] Full error: \(String(describing: error), privacy: .private)")
        }
    }
    
    /// Logs a network request (sanitized).
    public static func logNetworkRequest(url: URL, method: String = "GET", logger: Logger = network) {
        // Only log host, not full path which may contain sensitive info
        logger.info("[\(method, privacy: .public)] \(url.host ?? "unknown", privacy: .public)")
        if isDebugMode {
            logger.debug("Full URL: \(url.absoluteString, privacy: .private)")
        }
    }
    
    /// Logs transcription events.
    public static func logTranscription(event: String, model: String? = nil, wordCount: Int? = nil) {
        var message = "[\(event)]"
        if let model { message += " model=\(model)" }
        if let count = wordCount { message += " words=\(count)" }
        transcription.info("\(message, privacy: .public)")
    }
}

// MARK: - User-Facing Error Messages

/// Provides actionable error messages for common failure scenarios.
public enum SpeakErrorMessage {
    
    /// Returns a user-friendly message with actionable steps.
    public static func userMessage(for error: Error) -> (title: String, message: String, action: String?) {
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
        }
    }
    
    private static func handleSpeechError(_ error: NSError) -> (String, String, String?) {
        switch error.code {
        case 1: // Speech not available
            return (
                "Speech Recognition Unavailable",
                "Speech recognition is not available on this device.",
                "Ensure your device supports speech recognition and you have an internet connection for first-time setup."
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
    
    private static func handleAudioError(_ error: NSError) -> (String, String, String?) {
        return (
            "Audio Error",
            "Could not access the microphone.",
            "Go to Settings → Privacy & Security → Microphone and ensure Speak has access."
        )
    }
}

// MARK: - Permission Checker

/// Checks and reports permission status for required capabilities.
public struct PermissionStatus {
    public var microphone: PermissionState
    public var speechRecognition: PermissionState
    public var localNetwork: PermissionState
    
    public enum PermissionState: String {
        case granted
        case denied
        case notDetermined
        case restricted
    }
    
    public var allGranted: Bool {
        microphone == .granted && speechRecognition == .granted
    }
    
    public var missingPermissions: [String] {
        var missing: [String] = []
        if microphone != .granted { missing.append("Microphone") }
        if speechRecognition != .granted { missing.append("Speech Recognition") }
        return missing
    }
}

#if os(iOS)
import AVFoundation
import Speech

extension PermissionStatus {
    /// Gets current permission status (iOS).
    public static func current() async -> PermissionStatus {
        let micStatus: PermissionState
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: micStatus = .granted
        case .denied: micStatus = .denied
        case .undetermined: micStatus = .notDetermined
        @unknown default: micStatus = .notDetermined
        }
        
        let speechStatus: PermissionState
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechStatus = .granted
        case .denied: speechStatus = .denied
        case .notDetermined: speechStatus = .notDetermined
        case .restricted: speechStatus = .restricted
        @unknown default: speechStatus = .notDetermined
        }
        
        return PermissionStatus(
            microphone: micStatus,
            speechRecognition: speechStatus,
            localNetwork: .granted // Prompted on first use
        )
    }
}
#endif
