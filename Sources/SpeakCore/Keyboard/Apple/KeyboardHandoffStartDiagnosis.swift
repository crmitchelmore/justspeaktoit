import Foundation

/// Decides how the containing app starts a keyboard hand-off recording and
/// what the keyboard is told when it cannot (issue #1469).
///
/// The keyboard always runs in front of another app, so the containing app
/// normally starts these recordings from the background, kept alive by its
/// mixable Instant Dictation readiness session. iOS refuses a background app
/// that tries to make its audio session non-mixable, and a refused or
/// interrupted session cannot be re-activated for recording until the app is
/// in the foreground again. Inside the app's own text fields the app is in
/// front, which is why the same dictation worked there.
public enum KeyboardHandoffStartDiagnosis {
    /// The step of a hand-off start that failed, recorded in diagnostics.
    public enum Stage: String, Equatable, Sendable {
        /// The app was already recording or finishing another request.
        case busy
        /// The profile's transcription model has no usable credential.
        case credentials
        /// The profile's model or polish route is unavailable on this device.
        case profile
        /// The audio session, engine or provider failed to start.
        case recording
    }

    /// The audio session categories a recording may try, in order.
    public enum SessionCategory: String, Equatable, Sendable {
        /// Non-mixable `playAndRecord`: cleanest capture, foreground only.
        case isolated
        /// Mixable `playAndRecord`: permitted from the background.
        case mixable
    }

    /// The categories to attempt for a recording start.
    ///
    /// In the foreground the isolated session is preferred and the mixable one
    /// is the fallback. In the background only the mixable session is tried:
    /// switching an active background session to non-mixable is refused, and
    /// can interrupt the readiness session the keyboard hand-off depends on.
    public static func sessionCategories(applicationIsInForeground: Bool) -> [SessionCategory] {
        applicationIsInForeground ? [.isolated, .mixable] : [.mixable]
    }

    /// Whether the readiness engine must keep running while a hand-off records.
    ///
    /// iOS only lets a background app keep recording, never start: a new
    /// recording from the background fails with `cannotStartRecording`
    /// (`'!rec'`). Stopping the readiness engine first would make the
    /// dictation, and the readiness restart after it, exactly such a start.
    /// In the foreground the engine is still handed over, as before.
    public static func keepsReadinessRunningDuringRecording(
        applicationIsInForeground: Bool,
        readinessIsRunning: Bool
    ) -> Bool {
        !applicationIsInForeground && readinessIsRunning
    }

    /// `AVAudioSession` FourCC codes iOS uses to refuse audio for an app that
    /// is not allowed to take the microphone from where it is running.
    static let backgroundRefusalCodes: Set<String> = ["!int", "!pri", "!rec"]

    /// Whether `error` (or an error it wraps) is iOS refusing to start
    /// recording for an app that is not in the foreground.
    public static func isBackgroundAudioRefusal(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let candidate = current, depth < 4 {
            if let code = fourCharCode(candidate.code), backgroundRefusalCodes.contains(code) {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// The failure the keyboard is told about for a start that failed at `stage`.
    ///
    /// Only a recording failure is attributed to the microphone. A background
    /// refusal asks the user to open the app, because that is the only thing
    /// iOS accepts as a fix; nothing here blames the microphone permission,
    /// which readiness already proved was granted.
    public static func failureCode(
        stage: Stage,
        error: Error? = nil,
        applicationIsInForeground: Bool
    ) -> KeyboardHandoffRecord.FailureCode {
        switch stage {
        case .busy:
            return .recordingUnavailable
        case .credentials, .profile:
            return .profileUnavailable
        case .recording:
            if !applicationIsInForeground, let error, isBackgroundAudioRefusal(error) {
                return .appUnavailable
            }
            return .recordingUnavailable
        }
    }

    /// One privacy-safe log line describing a failed start.
    public static func diagnosticSummary(
        stage: Stage,
        error: Error?,
        applicationIsInForeground: Bool
    ) -> String {
        let failure = failureCode(stage: stage, error: error, applicationIsInForeground: applicationIsInForeground)
        var parts = [
            "stage=\(stage.rawValue)",
            "appForeground=\(applicationIsInForeground)",
            "failure=\(failure.rawValue)"
        ]
        if let error {
            let nsError = error as NSError
            parts.append("domain=\(nsError.domain)")
            parts.append("code=\(nsError.code)")
            if let fourCC = fourCharCode(nsError.code) {
                parts.append("fourCC='\(fourCC)'")
            }
            parts.append("backgroundRefusal=\(isBackgroundAudioRefusal(error))")
        }
        return parts.joined(separator: " ")
    }

    private static func fourCharCode(_ code: Int) -> String? {
        let value = UInt32(truncatingIfNeeded: code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}
