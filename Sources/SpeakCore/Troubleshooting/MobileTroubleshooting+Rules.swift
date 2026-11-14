import Foundation

extension MobileTroubleshooting {
    static func permissionFinding(_ check: Check, _ permission: Permission) -> Finding {
        let isMicrophone = check == .microphone
        let title = isMicrophone ? "Microphone" : "Speech Recognition"
        let image = isMicrophone ? "mic" : "waveform"
        let request: Fix = isMicrophone ? .requestMicrophone : .requestSpeechRecognition
        switch permission {
        case .granted:
            return Finding(
                check: check, title: "\(title) Allowed",
                detail: isMicrophone
                    ? "Just Speak can use the microphone."
                    : "The on-device recogniser is allowed for this app.",
                severity: .ok, systemImage: image
            )
        case .notDetermined:
            return Finding(
                check: check, title: "\(title) Not Allowed Yet",
                detail: "You have not been asked yet. Allow it now so the first recording does not stop for a prompt.",
                severity: .warning, fixes: [request], systemImage: image
            )
        case .denied:
            return Finding(
                check: check, title: "\(title) Is Turned Off",
                detail: isMicrophone
                    ? "Recording cannot start. Turn the microphone on for Just Speak in Settings."
                    : "The on-device model cannot run. Turn speech recognition on for Just Speak in Settings, "
                        + "or choose a cloud model.",
                severity: .issue,
                fixes: isMicrophone ? [.openSystemSettings] : [.openSystemSettings, .openTranscriptionSettings],
                systemImage: image
            )
        case .restricted:
            return Finding(
                check: check, title: "\(title) Is Restricted",
                detail: "A device policy such as Screen Time or a work profile blocks it. "
                    + "Whoever manages the device can lift the restriction.",
                severity: .issue, systemImage: image
            )
        }
    }

    static func recogniserFinding(_ recogniser: Recogniser) -> Finding? {
        let image = "cpu"
        switch recogniser {
        case .notRequired:
            return nil
        case .ready:
            return Finding(
                check: .recogniser, title: "On-Device Model Ready",
                detail: "The on-device recogniser supports your spoken language and is ready.",
                severity: .ok, systemImage: image
            )
        case .needsDownload:
            return Finding(
                check: .recogniser, title: "On-Device Model Not Downloaded",
                detail: "Your spoken language is supported, but its model is not on the device yet. "
                    + "The first recording downloads it, which can take a few minutes.",
                severity: .warning, fixes: [.openTranscriptionSettings], systemImage: image
            )
        case .unsupportedLanguage:
            return Finding(
                check: .recogniser, title: "Language Not Supported On Device",
                detail: "The on-device recogniser has no model for your spoken language. "
                    + "Choose another language or a cloud model.",
                severity: .issue, fixes: [.openTranscriptionSettings], systemImage: image
            )
        case .unavailable:
            return Finding(
                check: .recogniser, title: "On-Device Recogniser Unavailable",
                detail: "The system says the recogniser cannot run right now. It can return after a restart "
                    + "or once a download finishes; a cloud model works meanwhile.",
                severity: .warning, fixes: [.openTranscriptionSettings], systemImage: image
            )
        case .unknown:
            return Finding(
                check: .recogniser, title: "On-Device Model Not Checked",
                detail: "Could not ask the system about the on-device model. A recording will still try to use it.",
                severity: .info, systemImage: image
            )
        }
    }

    static func keyFinding(_ check: Check, _ provider: Provider, role: String) -> Finding? {
        guard let name = provider.name, provider.key != .notRequired else { return nil }
        let isCleanup = check == .postProcessingKey
        let image = "key"
        switch provider.key {
        case .notRequired:
            return nil
        case .present:
            return Finding(
                check: check, title: "\(role) Key Saved",
                detail: provider.canVerify
                    ? "A \(name) key is saved. Check it to confirm \(name) accepts it."
                    : "A \(name) key is saved. \(name) checks it when a recording connects.",
                severity: .ok, fixes: provider.canVerify ? [.verifyKey] : [], systemImage: image
            )
        case .missing:
            return Finding(
                check: check, title: "\(role) Needs a \(name) Key",
                detail: isCleanup
                    ? "Cleanup is on and its model uses \(name). Add the key, or turn cleanup off."
                    : "The selected model uses \(name), and no key is saved. Add one or choose another model.",
                severity: .issue,
                fixes: isCleanup ? [.openAPIKeys, .disablePostProcessing] : [.openAPIKeys, .openTranscriptionSettings],
                systemImage: image
            )
        case .rejected:
            return Finding(
                check: check, title: "\(name) Rejected the \(role) Key",
                detail: "\(name) did not accept the saved key. Replace it with a current key from your account.",
                severity: .issue,
                fixes: isCleanup ? [.openAPIKeys, .disablePostProcessing] : [.openAPIKeys],
                systemImage: image
            )
        case .unreadable:
            return Finding(
                check: check, title: "\(role) Key Could Not Be Read",
                detail: "Saved keys could not be read, often because the device has not been unlocked since it "
                    + "restarted. This does not mean the key is missing.",
                severity: .warning, fixes: [.openAPIKeys], systemImage: image
            )
        }
    }

    static func keyboardFinding(_ keyboard: Keyboard) -> Finding? {
        let image = "keyboard"
        switch keyboard {
        case .notOffered:
            return nil
        case .notAdded:
            return Finding(
                check: .keyboard, title: "Keyboard Not Set Up",
                detail: "The Just Speak keyboard has not been used yet. Add it to dictate in other apps.",
                severity: .info, fixes: [.openKeyboardSetup], systemImage: image
            )
        case .needsFullAccess:
            return Finding(
                check: .keyboard, title: "Keyboard Needs Full Access",
                detail: "The keyboard is added, but without Full Access it cannot hand dictation to the app "
                    + "or read its transcript back.",
                severity: .warning, fixes: [.openKeyboardSetup, .openSystemSettings], systemImage: image
            )
        case .ready:
            return Finding(
                check: .keyboard, title: "Keyboard Ready",
                detail: "The keyboard is added and has Full Access.",
                severity: .ok, systemImage: image
            )
        }
    }
}
