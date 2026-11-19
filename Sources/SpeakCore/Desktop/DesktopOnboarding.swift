import Foundation

/// The desktop first-run guide, shared by every desktop host so the steps,
/// wording and completion rule match the Mac's onboarding.
///
/// The Mac stores completion under `hasCompletedOnboarding` in its settings
/// domain (see `DataMigrationPreferenceCatalog`). Desktop hosts persist the
/// same key in their own state file, so a backup or a future settings import
/// sees one canonical name.
public enum DesktopOnboardingStep: String, CaseIterable, Codable, Sendable {
    case welcome
    case microphone
    case textInsertion
    case transcriptionRoute
    case hotkeyPractice
    case postProcessing
    case done

    public var title: String {
        switch self {
        case .welcome: return "Welcome to Just Speak to It"
        case .microphone: return "Microphone access"
        case .textInsertion: return "Typing into other apps"
        case .transcriptionRoute: return "Choose how speech becomes text"
        case .hotkeyPractice: return "Practise the shortcut"
        case .postProcessing: return "Optional: polish transcripts"
        case .done: return "You're all set"
        }
    }

    public var detail: String {
        switch self {
        case .welcome:
            return "Speak instead of typing, in any app. This short setup checks your microphone, "
                + "chooses a speech model and shows you the shortcut. You can run it again at any time."
        case .microphone:
            return "The app records only while you dictate. Make sure the system lets desktop apps use the "
                + "microphone, then choose the microphone you want."
        case .textInsertion:
            return "Finished text is typed into the app you were using, or copied when that is not possible. "
                + "Apps running as administrator cannot receive text from an app that is not."
        case .transcriptionRoute:
            return "Use your own provider key for a remote model, or download a model that runs entirely on "
                + "this computer. You can change this later."
        case .hotkeyPractice:
            return "Press the shortcut in any app, speak, and press it again (or release it) to insert the text. "
                + "Try it now with a short test dictation."
        case .postProcessing:
            return "An optional model can tidy punctuation and wording after each recording. "
                + "The original transcript is always kept. Skip this if you are not sure."
        case .done:
            return "Press the shortcut whenever you want to dictate. Settings, Permissions and this setup "
                + "stay available from the app."
        }
    }

    public var isOptional: Bool { self == .postProcessing }

    public var next: DesktopOnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    public var previous: DesktopOnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    /// One-based position for "Step 2 of 7".
    public var position: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public var progress: String { "Step \(position) of \(Self.allCases.count)" }

    /// The step's buttons, in display order; hosts show only actions they implement.
    public var actions: [DesktopOnboardingAction] {
        switch self {
        case .welcome, .done: return [.openPermissions]
        case .microphone: return [.openMicrophoneSettings, .chooseMicrophone]
        case .textInsertion: return [.chooseTextOutput, .openPermissions]
        case .transcriptionRoute: return [.chooseRemoteProvider, .downloadLocalModel]
        case .hotkeyPractice: return [.chooseShortcut, .testDictation]
        case .postProcessing: return [.openPostProcessing]
        }
    }
}

/// A step button. Raw values cross the hosts' native event boundary.
public enum DesktopOnboardingAction: String, CaseIterable, Sendable {
    case openMicrophoneSettings
    case chooseMicrophone
    case chooseTextOutput
    case chooseRemoteProvider
    case downloadLocalModel
    case chooseShortcut
    case testDictation
    case openPostProcessing
    case openPermissions

    public var title: String {
        switch self {
        case .openMicrophoneSettings: return "Open microphone privacy settings"
        case .chooseMicrophone: return "Choose microphone..."
        case .chooseTextOutput: return "Text output..."
        case .chooseRemoteProvider: return "Use a provider key..."
        case .downloadLocalModel: return "Download a local model..."
        case .chooseShortcut: return "Change shortcut..."
        case .testDictation: return "Start a test dictation"
        case .openPostProcessing: return "Post-processing settings..."
        case .openPermissions: return "Permissions..."
        }
    }
}

/// The persisted onboarding state. Encodes `hasCompletedOnboarding`, the
/// Mac's canonical key, and the last step reached so a guide closed midway
/// resumes there.
public struct DesktopOnboardingState: Codable, Equatable, Sendable {
    public static let completionKey = "hasCompletedOnboarding"
    public static let fileName = "onboarding.json"

    public var hasCompletedOnboarding: Bool
    public var lastStep: DesktopOnboardingStep?

    public init(hasCompletedOnboarding: Bool = false, lastStep: DesktopOnboardingStep? = nil) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.lastStep = lastStep
    }

    /// Where to open the guide: a finished guide starts again from Welcome.
    public var resumeStep: DesktopOnboardingStep {
        guard !hasCompletedOnboarding, let lastStep, lastStep != .done else { return .welcome }
        return lastStep
    }

    /// Reads saved state. Without a state file, an install that already has
    /// settings predates the guide and is treated as onboarded, so upgrades
    /// never see the first-run guide; a fresh install has neither file.
    public static func load(stateData: Data?, hasExistingSettings: Bool) -> DesktopOnboardingState {
        guard let stateData else { return DesktopOnboardingState(hasCompletedOnboarding: hasExistingSettings) }
        return (try? JSONDecoder().decode(DesktopOnboardingState.self, from: stateData))
            ?? DesktopOnboardingState(hasCompletedOnboarding: true)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// What the Permissions page checks on a desktop host.
public enum DesktopPermissionKind: String, CaseIterable, Sendable {
    case microphone
    case textInsertion
    case elevation
    case automation
    case notifications
    case startup

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .textInsertion: return "Text insertion"
        case .elevation: return "Administrator apps"
        case .automation: return "Automation"
        case .notifications: return "Notifications"
        case .startup: return "Launch at login"
        }
    }

    /// Plain-language guidance, as the Mac's permission help.
    public var guidance: String {
        switch self {
        case .microphone:
            return "Needed to record. If recording fails, allow microphone access for desktop apps in the "
                + "system's privacy settings, then choose Check again."
        case .textInsertion:
            return "Lets finished text be typed into the app you were using. When it is unavailable, text is "
                + "copied so you can paste it."
        case .elevation:
            return "Windows blocks typing into apps running as administrator from an app that is not. Run both "
                + "the same way, or paste the copied text instead."
        case .automation:
            return "Optional. Lets the speak command control this app for your account. Turn it on in General."
        case .notifications:
            return "Optional. Lets the app tell you when a transcription finishes while it is in the background."
        case .startup:
            return "Optional. Starts the app when you sign in so the shortcut is always ready."
        }
    }

    /// Blocking kinds stop dictation from working at all; the rest are optional.
    public var isEssential: Bool { self == .microphone || self == .textInsertion }
}

public enum DesktopPermissionStatus: String, Sendable, Equatable {
    case granted
    case denied
    case warning
    case off
    case unknown
    case notApplicable

    public var label: String {
        switch self {
        case .granted: return "Allowed"
        case .denied: return "Blocked"
        case .warning: return "Needs attention"
        case .off: return "Off"
        case .unknown: return "Not detected"
        case .notApplicable: return "Not needed"
        }
    }
}

public struct DesktopPermissionItem: Equatable, Sendable {
    public var kind: DesktopPermissionKind
    public var status: DesktopPermissionStatus
    /// The observed state in a sentence, for example which switch is off.
    public var detail: String
    /// Remediation button title; nil when nothing can be opened.
    public var remediationTitle: String?

    public init(
        kind: DesktopPermissionKind, status: DesktopPermissionStatus, detail: String,
        remediationTitle: String? = nil
    ) {
        self.kind = kind
        self.status = status
        self.detail = detail
        self.remediationTitle = remediationTitle
    }

    /// Essential items denied or needing attention block dictation.
    public var isBlocking: Bool { kind.isEssential && (status == .denied || status == .warning) }
}

public enum DesktopPermissionSummary {
    /// The dashboard warning, or nil when nothing essential is blocked.
    public static func blockingMessage(_ items: [DesktopPermissionItem]) -> String? {
        let blocked = items.filter(\.isBlocking)
        guard !blocked.isEmpty else { return nil }
        if blocked.count == 1, let only = blocked.first {
            return "\(only.kind.title): \(only.status.label.lowercased()). Open Permissions to fix it."
        }
        return "\(blocked.map(\.kind.title).joined(separator: " and ")) need attention. Open Permissions to fix them."
    }

    /// The result of Check again, mirroring the Mac's recovery help.
    public static func recheckMessage(_ items: [DesktopPermissionItem]) -> String {
        let remaining = items.filter { $0.kind.isEssential && $0.status != .granted && $0.status != .notApplicable }
        guard !remaining.isEmpty else { return "All required permissions are detected for this app." }
        return "Still not detected: \(remaining.map(\.kind.title).joined(separator: ", "))."
    }
}
