// The Capture Health report (issue #997).
//
// The point of this screen is a person whose Action Button "does nothing"
// finding out which precondition is actually broken, so the whole value of it
// rests on every row being true. A row that says "OK" because a switch is on
// is the #952 failure again — a pairing screen that looked configured and
// never sent a single transcript to anything.
//
// So every check declares what kind of evidence it is, and the kind is part of
// the row the user reads, not a footnote:
//
//   * `.exercised`    — this check just did the thing and it worked.
//   * `.configuration` — this check read a switch or an authorisation. It
//                        proves the setting, and says nothing about whether
//                        capture works.
//   * `.observed`     — this check reports what happened on real earlier runs.
//
// Privacy is a property of the input type, not a promise in a comment.
// ``CaptureHealthProbe`` holds enums, booleans, whole numbers and dates and
// nothing else. There is no `String` field on it, so no transcript, prompt,
// credential, device name, audio route, locale identifier or file path can
// reach a health row even by accident, and no future field can add one without
// breaking `CaptureHealthProbeShapeTests`. Nothing in this file transmits
// anything: the report is built for one screen on one device and there is
// deliberately no way to send it anywhere. Vendor reporting is issue #776's
// problem, with issue #776's consent.
import Foundation
import Security

// MARK: - Evidence kinds

/// What kind of evidence a row is. Shown to the user, because "the switch is
/// on" and "I just did it and it worked" are different promises.
public enum CaptureHealthEvidence: String, Equatable, Sendable, CaseIterable {
    case exercised
    case configuration
    case observed

    /// The words on the row's badge.
    public var label: String {
        switch self {
        case .exercised: return "Tested"
        case .configuration: return "Setting"
        case .observed: return "Recorded"
        }
    }

    /// The sentence explaining what the badge is worth.
    public var explanation: String {
        switch self {
        case .exercised:
            return "This check ran the thing it describes, just now, and reports what happened."
        case .configuration:
            return "This check reads a setting or a permission. It shows the switch is on — not that capture works."
        case .observed:
            return "This check reports what earlier captures on this device actually did."
        }
    }
}

public enum CaptureHealthStatus: String, Equatable, Sendable, CaseIterable {
    /// Working, or set the way capture needs it.
    case healthy
    /// Usable, but degraded or worth knowing about.
    case attention
    /// Capture will not work, or did not.
    case broken
    /// Not established. Never rendered as healthy.
    case undetermined
    /// Does not apply on this device or in this configuration.
    case notApplicable
}

public enum CaptureHealthCheckID: String, Equatable, Sendable, CaseIterable {
    case microphonePermission
    case speechPermission
    case appGroupContainer
    case credentialStore
    case credentialAccessibility
    case safetyRecordingStorage
    case liveActivities
    case speechAssets
    case keyboardReadiness
    case recentCaptures
    case unrecoveredCaptures
    case microphoneSelfTest

    public var title: String {
        switch self {
        case .microphonePermission: return "Microphone permission"
        case .speechPermission: return "Speech recognition permission"
        case .appGroupContainer: return "Shared container"
        case .credentialStore: return "Provider key"
        case .credentialAccessibility: return "Key readable while locked"
        case .safetyRecordingStorage: return "Safety recording storage"
        case .liveActivities: return "Live Activities"
        case .speechAssets: return "On-device speech model"
        case .keyboardReadiness: return "Keyboard instant dictation"
        case .recentCaptures: return "Recent captures"
        case .unrecoveredCaptures: return "Unrecovered audio"
        case .microphoneSelfTest: return "Microphone self-test"
        }
    }

    /// The kind of evidence this row can ever carry. Fixed per check, so a row
    /// cannot quietly downgrade from a real exercise to a settings read.
    public var evidence: CaptureHealthEvidence {
        switch self {
        case .microphonePermission, .speechPermission, .liveActivities, .speechAssets:
            return .configuration
        case .appGroupContainer, .credentialStore, .credentialAccessibility,
             .safetyRecordingStorage, .microphoneSelfTest:
            return .exercised
        case .keyboardReadiness, .recentCaptures, .unrecoveredCaptures:
            return .observed
        }
    }
}

// MARK: - Closed-set probe results

public enum CaptureHealthPermission: String, Equatable, Sendable {
    case granted
    case denied
    case undetermined
    case restricted
}

/// The result of actually trying something, rather than asking about it.
public enum CaptureHealthExercise: String, Equatable, Sendable {
    case succeeded
    case failed
    case notAttempted
}

/// The keychain accessibility class an item was found to carry. Closed set:
/// the raw `kSecAttrAccessible` string never leaves the probe.
public enum CaptureHealthAccessibility: String, Equatable, Sendable {
    case whenUnlocked
    case afterFirstUnlock
    case whenPasscodeSet
    case other

    /// Narrows a raw `kSecAttrAccessible` value to the closed set. Anything
    /// unrecognised becomes ``other`` rather than being carried through, so
    /// the raw keychain string cannot reach a health row.
    public init(secAttrAccessible: String) {
        let afterFirstUnlock = [
            kSecAttrAccessibleAfterFirstUnlock as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        ]
        let whenUnlocked = [
            kSecAttrAccessibleWhenUnlocked as String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        ]
        if afterFirstUnlock.contains(secAttrAccessible) {
            self = .afterFirstUnlock
        } else if whenUnlocked.contains(secAttrAccessible) {
            self = .whenUnlocked
        } else if secAttrAccessible == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String {
            self = .whenPasscodeSet
        } else {
            self = .other
        }
    }
}

public enum CaptureHealthAssetState: String, Equatable, Sendable {
    case installed
    case downloading
    case notInstalled
    case unsupportedLocale
    /// The selected transcription does not use an on-device speech model, so
    /// there is nothing here to be wrong.
    case notRequired
}

/// How the last capture that the device recorded an outcome for ended.
public enum CaptureHealthLastOutcome: String, Equatable, Sendable, CaseIterable {
    case delivered
    case startFailed
    case noInput
    case finalisationTimedOut
    case cancelled
    /// Ended with an error that is none of the named ones. Reported as a
    /// failure rather than folded into one of them, because guessing which
    /// bound it hit would put words in the diagnostics' mouth.
    case failed
}

// MARK: - Probe

/// Facts gathered on device, in the only shape a health row is allowed to see.
///
/// Every field is an enum, a `Bool`, an `Int` or a `Date`. That is the privacy
/// guarantee of this screen, enforced by a test rather than by discipline.
public struct CaptureHealthProbe: Equatable, Sendable {
    public var microphone: CaptureHealthPermission
    public var speech: CaptureHealthPermission
    /// Written a probe value into the App Group container and read it back.
    public var appGroupRoundTrip: CaptureHealthExercise
    /// Looked the configured provider's key up in the keychain. `nil` when the
    /// selected provider needs no key (an on-device model).
    public var credentialLookup: CaptureHealthExercise?
    /// The accessibility class the stored key actually carries (issue #930).
    public var credentialAccessibility: CaptureHealthAccessibility?
    /// Created, wrote and removed a probe file where safety recordings go.
    public var recordingStorageRoundTrip: CaptureHealthExercise
    public var liveActivitiesEnabled: Bool?
    public var speechAssets: CaptureHealthAssetState?
    /// Age of the keyboard readiness heartbeat, whole seconds. `nil` when the
    /// keyboard has never reported.
    public var keyboardHeartbeatAgeSeconds: Int?
    public var keyboardResumeAttemptsSpent: Int?
    public var lastCaptureOutcome: CaptureHealthLastOutcome?
    public var lastCaptureAgeSeconds: Int?
    /// From the recovery pass (issue #992): captures whose audio survived a
    /// crash and has not been transcribed yet.
    public var recoverableCaptureCount: Int
    /// Captures whose audio is being kept because the pass could not tell what
    /// it was. Kept, never deleted.
    public var uncertainCaptureCount: Int
    public var selfTest: CaptureSelfTestResult?

    public init(
        microphone: CaptureHealthPermission = .undetermined,
        speech: CaptureHealthPermission = .undetermined,
        appGroupRoundTrip: CaptureHealthExercise = .notAttempted,
        credentialLookup: CaptureHealthExercise? = nil,
        credentialAccessibility: CaptureHealthAccessibility? = nil,
        recordingStorageRoundTrip: CaptureHealthExercise = .notAttempted,
        liveActivitiesEnabled: Bool? = nil,
        speechAssets: CaptureHealthAssetState? = nil,
        keyboardHeartbeatAgeSeconds: Int? = nil,
        keyboardResumeAttemptsSpent: Int? = nil,
        lastCaptureOutcome: CaptureHealthLastOutcome? = nil,
        lastCaptureAgeSeconds: Int? = nil,
        recoverableCaptureCount: Int = 0,
        uncertainCaptureCount: Int = 0,
        selfTest: CaptureSelfTestResult? = nil
    ) {
        self.microphone = microphone
        self.speech = speech
        self.appGroupRoundTrip = appGroupRoundTrip
        self.credentialLookup = credentialLookup
        self.credentialAccessibility = credentialAccessibility
        self.recordingStorageRoundTrip = recordingStorageRoundTrip
        self.liveActivitiesEnabled = liveActivitiesEnabled
        self.speechAssets = speechAssets
        self.keyboardHeartbeatAgeSeconds = keyboardHeartbeatAgeSeconds
        self.keyboardResumeAttemptsSpent = keyboardResumeAttemptsSpent
        self.lastCaptureOutcome = lastCaptureOutcome
        self.lastCaptureAgeSeconds = lastCaptureAgeSeconds
        self.recoverableCaptureCount = recoverableCaptureCount
        self.uncertainCaptureCount = uncertainCaptureCount
        self.selfTest = selfTest
    }
}

// MARK: - Rows

public struct CaptureHealthCheck: Identifiable, Equatable, Sendable {
    public let id: CaptureHealthCheckID
    public let status: CaptureHealthStatus
    /// One sentence, assembled here from closed-set labels and whole numbers.
    public let detail: String

    public var title: String { self.id.title }
    public var evidence: CaptureHealthEvidence { self.id.evidence }

    public init(id: CaptureHealthCheckID, status: CaptureHealthStatus, detail: String) {
        self.id = id
        self.status = status
        self.detail = detail
    }
}

public struct CaptureHealthReport: Equatable, Sendable {
    public let checks: [CaptureHealthCheck]

    public init(checks: [CaptureHealthCheck]) {
        self.checks = checks
    }

    /// The worst status in the report, which is what the summary line says.
    /// `undetermined` outranks `healthy` deliberately: a screen that has not
    /// established something must not present itself as green.
    public var overall: CaptureHealthStatus {
        let ranked: [CaptureHealthStatus] = [.broken, .attention, .undetermined, .healthy]
        for status in ranked where self.checks.contains(where: { $0.status == status }) {
            return status
        }
        return .undetermined
    }

    public func check(_ id: CaptureHealthCheckID) -> CaptureHealthCheck? {
        self.checks.first { $0.id == id }
    }

    /// Rows the user is being asked to act on.
    public var problems: [CaptureHealthCheck] {
        self.checks.filter { $0.status == .broken || $0.status == .attention }
    }
}
