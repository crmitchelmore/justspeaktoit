// Building the Capture Health report (issue #997).
//
// Split from the types only to keep each file readable: every verdict below is
// a pure function of the closed-set probe, and each one is proved by
// `CaptureHealthReportTests`.
import Foundation

extension CaptureHealthReport {
    // MARK: Building

    public static func build(from probe: CaptureHealthProbe) -> CaptureHealthReport {
        var checks: [CaptureHealthCheck] = []

        checks.append(Self.permissionCheck(.microphonePermission, probe.microphone))
        checks.append(Self.permissionCheck(.speechPermission, probe.speech))

        checks.append(Self.exerciseCheck(
            .appGroupContainer,
            probe.appGroupRoundTrip,
            success: "Wrote a value into the shared container and read it back.",
            failure: "Could not write and read back a value. Headless triggers cannot pass state to the app.",
            notAttempted: "Not checked."
        ))

        if let credentialLookup = probe.credentialLookup {
            checks.append(Self.exerciseCheck(
                .credentialStore,
                credentialLookup,
                success: "Read the selected provider's key out of the keychain.",
                failure: "The selected provider's key is not readable. Capture will fall back or fail.",
                notAttempted: "Not checked."
            ))
        } else {
            checks.append(CaptureHealthCheck(
                id: .credentialStore,
                status: .notApplicable,
                detail: "The selected transcription runs on device and needs no key."
            ))
        }

        checks.append(Self.accessibilityCheck(probe.credentialAccessibility))

        checks.append(Self.exerciseCheck(
            .safetyRecordingStorage,
            probe.recordingStorageRoundTrip,
            success: "Created, wrote and removed a probe file where safety recordings are kept.",
            failure: "Could not write where safety recordings are kept. Audio would not survive a crash.",
            notAttempted: "Not checked."
        ))

        checks.append(Self.liveActivityCheck(probe.liveActivitiesEnabled))
        checks.append(Self.assetCheck(probe.speechAssets))
        checks.append(Self.keyboardCheck(
            ageSeconds: probe.keyboardHeartbeatAgeSeconds,
            attemptsSpent: probe.keyboardResumeAttemptsSpent
        ))
        checks.append(Self.recentCaptureCheck(
            outcome: probe.lastCaptureOutcome,
            ageSeconds: probe.lastCaptureAgeSeconds
        ))
        checks.append(Self.recoveryCheck(
            recoverable: probe.recoverableCaptureCount,
            uncertain: probe.uncertainCaptureCount
        ))
        checks.append(Self.selfTestCheck(probe.selfTest))

        return CaptureHealthReport(checks: checks)
    }

    private static func permissionCheck(
        _ id: CaptureHealthCheckID,
        _ permission: CaptureHealthPermission
    ) -> CaptureHealthCheck {
        switch permission {
        case .granted:
            // Deliberately not "working": a granted permission is a switch,
            // and a granted microphone can still deliver no buffers.
            return CaptureHealthCheck(id: id, status: .healthy, detail: "Granted.")
        case .denied:
            return CaptureHealthCheck(id: id, status: .broken, detail: "Denied. Capture cannot start.")
        case .restricted:
            return CaptureHealthCheck(id: id, status: .broken, detail: "Restricted by device policy.")
        case .undetermined:
            return CaptureHealthCheck(
                id: id,
                status: .attention,
                detail: "Not asked yet. The first capture will prompt."
            )
        }
    }

    private static func exerciseCheck(
        _ id: CaptureHealthCheckID,
        _ exercise: CaptureHealthExercise,
        success: String,
        failure: String,
        notAttempted: String
    ) -> CaptureHealthCheck {
        switch exercise {
        case .succeeded: return CaptureHealthCheck(id: id, status: .healthy, detail: success)
        case .failed: return CaptureHealthCheck(id: id, status: .broken, detail: failure)
        case .notAttempted: return CaptureHealthCheck(id: id, status: .undetermined, detail: notAttempted)
        }
    }

    private static func accessibilityCheck(
        _ accessibility: CaptureHealthAccessibility?
    ) -> CaptureHealthCheck {
        guard let accessibility else {
            return CaptureHealthCheck(
                id: .credentialAccessibility,
                status: .undetermined,
                detail: "No stored key to inspect."
            )
        }
        switch accessibility {
        case .afterFirstUnlock:
            return CaptureHealthCheck(
                id: .credentialAccessibility,
                status: .healthy,
                detail: "Stored so it can be read after the first unlock, including from a locked pocket capture."
            )
        case .whenUnlocked, .whenPasscodeSet:
            // Issue #930: this is the silent downgrade to Apple Speech.
            return CaptureHealthCheck(
                id: .credentialAccessibility,
                status: .broken,
                detail: "Stored as readable only while unlocked, so a locked-device capture cannot use this provider."
            )
        case .other:
            return CaptureHealthCheck(
                id: .credentialAccessibility,
                status: .attention,
                detail: "Stored with an accessibility class this screen does not recognise."
            )
        }
    }

    private static func liveActivityCheck(_ enabled: Bool?) -> CaptureHealthCheck {
        guard let enabled else {
            return CaptureHealthCheck(
                id: .liveActivities,
                status: .notApplicable,
                detail: "Not available on this device."
            )
        }
        return enabled
            ? CaptureHealthCheck(id: .liveActivities, status: .healthy, detail: "Allowed for this app.")
            : CaptureHealthCheck(
                id: .liveActivities,
                status: .attention,
                detail: "Turned off, so a capture shows no Live Activity and cannot be stopped from the Lock Screen."
            )
    }

    private static func assetCheck(_ state: CaptureHealthAssetState?) -> CaptureHealthCheck {
        guard let state else {
            return CaptureHealthCheck(id: .speechAssets, status: .undetermined, detail: "Not checked.")
        }
        switch state {
        case .installed:
            return CaptureHealthCheck(id: .speechAssets, status: .healthy, detail: "Installed for the chosen language.")
        case .downloading:
            return CaptureHealthCheck(
                id: .speechAssets,
                status: .attention,
                detail: "Still downloading. A capture started now may wait for it."
            )
        case .notInstalled:
            return CaptureHealthCheck(
                id: .speechAssets,
                status: .attention,
                detail: "Not installed. The first capture downloads it, which can take minutes."
            )
        case .unsupportedLocale:
            return CaptureHealthCheck(
                id: .speechAssets,
                status: .broken,
                detail: "The chosen language has no on-device model."
            )
        case .notRequired:
            return CaptureHealthCheck(
                id: .speechAssets,
                status: .notApplicable,
                detail: "The selected transcription does not use an on-device model."
            )
        }
    }

    private static func keyboardCheck(ageSeconds: Int?, attemptsSpent: Int?) -> CaptureHealthCheck {
        guard let ageSeconds else {
            return CaptureHealthCheck(
                id: .keyboardReadiness,
                status: .undetermined,
                detail: "The keyboard has not reported since this app was installed."
            )
        }
        let attempts = attemptsSpent ?? 0
        let window = Int(InstantDictationReadinessPolicy.sessionWindowSeconds)
        if ageSeconds > window {
            return CaptureHealthCheck(
                id: .keyboardReadiness,
                status: .attention,
                detail: "Last reported \(Self.duration(ageSeconds)) ago, past its \(Self.duration(window)) window. "
                    + "It re-arms when the keyboard next appears."
            )
        }
        if attempts >= InstantDictationReadinessPolicy.maximumResumeAttempts {
            return CaptureHealthCheck(
                id: .keyboardReadiness,
                status: .attention,
                detail: "Ready \(Self.duration(ageSeconds)) ago, after spending all "
                    + "\(InstantDictationReadinessPolicy.maximumResumeAttempts) resume attempts."
            )
        }
        return CaptureHealthCheck(
            id: .keyboardReadiness,
            status: .healthy,
            detail: "Reported ready \(Self.duration(ageSeconds)) ago, \(attempts) resume attempts spent."
        )
    }

    private static func recentCaptureCheck(
        outcome: CaptureHealthLastOutcome?,
        ageSeconds: Int?
    ) -> CaptureHealthCheck {
        guard let outcome else {
            return CaptureHealthCheck(
                id: .recentCaptures,
                status: .undetermined,
                detail: "No capture outcome has been recorded on this device yet."
            )
        }
        let when = ageSeconds.map { " \(Self.duration($0)) ago" } ?? ""
        switch outcome {
        case .delivered:
            return CaptureHealthCheck(
                id: .recentCaptures,
                status: .healthy,
                detail: "The last capture\(when) delivered its transcript."
            )
        case .cancelled:
            return CaptureHealthCheck(
                id: .recentCaptures,
                status: .healthy,
                detail: "The last capture\(when) was cancelled."
            )
        case .startFailed:
            return CaptureHealthCheck(
                id: .recentCaptures,
                status: .broken,
                detail: "The last capture\(when) never finished starting."
            )
        case .noInput:
            return CaptureHealthCheck(
                id: .recentCaptures,
                status: .broken,
                detail: "The last capture\(when) received no audio at all from the microphone."
            )
        case .finalisationTimedOut:
            return CaptureHealthCheck(
                id: .recentCaptures,
                status: .broken,
                detail: "The last capture\(when) recorded audio but its provider never returned a transcript."
            )
        case .failed:
            return CaptureHealthCheck(
                id: .recentCaptures,
                status: .broken,
                detail: "The last capture\(when) ended with an error."
            )
        }
    }

    private static func recoveryCheck(recoverable: Int, uncertain: Int) -> CaptureHealthCheck {
        if recoverable > 0 {
            return CaptureHealthCheck(
                id: .unrecoveredCaptures,
                status: .attention,
                detail: "\(recoverable) interrupted \(Self.captures(recoverable)) still holding audio that was "
                    + "never transcribed. The audio is kept until you choose."
            )
        }
        if uncertain > 0 {
            return CaptureHealthCheck(
                id: .unrecoveredCaptures,
                status: .attention,
                detail: "\(uncertain) \(Self.captures(uncertain)) kept because this device could not tell what "
                    + "happened to them. Nothing was deleted."
            )
        }
        return CaptureHealthCheck(
            id: .unrecoveredCaptures,
            status: .healthy,
            detail: "No interrupted capture is waiting to be recovered."
        )
    }

    private static func selfTestCheck(_ result: CaptureSelfTestResult?) -> CaptureHealthCheck {
        guard let result else {
            return CaptureHealthCheck(
                id: .microphoneSelfTest,
                status: .undetermined,
                detail: "Not run. Run it to find out whether the microphone actually delivers audio to this app."
            )
        }
        switch result.outcome {
        case .passed:
            let frames = result.observedBuffers
            return CaptureHealthCheck(
                id: .microphoneSelfTest,
                status: .healthy,
                detail: "Opened the microphone and received \(frames) audio \(Self.buffers(frames)) in "
                    + "\(result.elapsedMilliseconds) ms, then closed it."
            )
        case .failed(let stage):
            return CaptureHealthCheck(
                id: .microphoneSelfTest,
                status: .broken,
                detail: "Stopped at \(stage.label). \(stage.failureMeaning)"
            )
        case .cancelled:
            return CaptureHealthCheck(
                id: .microphoneSelfTest,
                status: .undetermined,
                detail: "Cancelled before it finished. The microphone was closed."
            )
        }
    }

    // MARK: Wording

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(0, seconds))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    private static func captures(_ count: Int) -> String {
        count == 1 ? "capture" : "captures"
    }

    private static func buffers(_ count: Int) -> String {
        count == 1 ? "buffer" : "buffers"
    }
}
