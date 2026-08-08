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
