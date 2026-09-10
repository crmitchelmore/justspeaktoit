import Foundation

/// How a transcript reached the user.
///
/// The cases are deliberately the things the app can actually *observe*, not
/// the things a marketing screen would like to claim. iOS runs Back Tap, an
/// Apple Pencil squeeze, a Siri phrase and an Action Button bound to a
/// Shortcut through the very same App Intent, so the app cannot tell them
/// apart; they all report `.shortcut`. The native "Transcribe Voice" Control
/// is a separate intent, so it reports `.control` whether the user reached it
/// from the Action Button's Controls picker, Control Centre or the Lock
/// Screen.
public enum CaptureTrigger: String, Codable, Sendable, CaseIterable {
    /// The microphone button inside the app.
    case inApp
    /// The native Control (`ToggleTranscriptionControlIntent`).
    case control
    /// A Shortcuts-run intent: Back Tap, Siri, Pencil squeeze, Action Button shortcut.
    case shortcut
    /// The Just Speak keyboard extension's hand-off.
    case keyboard
}

/// What this particular device can actually be set up with.
///
/// Everything here is a capability, never a claim that the user has done the
/// setup. `CaptureOnboardingPolicy` uses it only to decide which cards are
/// worth offering at all.
public struct CaptureHardwareProfile: Equatable, Sendable {
    /// The device has a physical Action Button (only changes the card's copy —
    /// the Control card is offered on every iOS 18 device).
    public var hasActionButton: Bool
    /// iOS 18 or later, where the app's Control can be placed by the user.
    public var supportsNativeControls: Bool
    /// A device that can run a Shortcut from a gesture (Back Tap, Pencil, Siri).
    public var supportsShortcutGestures: Bool
    /// A device that can install the custom keyboard.
    public var supportsKeyboardExtension: Bool

    public init(
        hasActionButton: Bool,
        supportsNativeControls: Bool,
        supportsShortcutGestures: Bool,
        supportsKeyboardExtension: Bool
    ) {
        self.hasActionButton = hasActionButton
        self.supportsNativeControls = supportsNativeControls
        self.supportsShortcutGestures = supportsShortcutGestures
        self.supportsKeyboardExtension = supportsKeyboardExtension
    }

    public func supports(_ trigger: CaptureTrigger) -> Bool {
        switch trigger {
        // The in-app microphone is never a setup card; it is the thing the
        // first-run sheet already proves.
        case .inApp: false
        case .control: self.supportsNativeControls
        case .shortcut: self.supportsShortcutGestures
        case .keyboard: self.supportsKeyboardExtension
        }
    }
}

/// Everything onboarding remembers between launches.
public struct CaptureOnboardingState: Codable, Equatable, Sendable {
    /// The first-run sheet ran to its end (or the user skipped it explicitly).
    public var firstRunCompleted: Bool
    /// Dictations that produced a non-blank transcript, from any trigger.
    public var successfulDictations: Int
    /// Triggers a real transcript has actually arrived through.
    public var provenTriggers: Set<CaptureTrigger>
    /// Cards the user has waved away. Dismissal is permanent: one card per
    /// trigger, never a second showing.
    public var dismissedCards: Set<CaptureTrigger>

    public init(
        firstRunCompleted: Bool = false,
        successfulDictations: Int = 0,
        provenTriggers: Set<CaptureTrigger> = [],
        dismissedCards: Set<CaptureTrigger> = []
    ) {
        self.firstRunCompleted = firstRunCompleted
        self.successfulDictations = successfulDictations
        self.provenTriggers = provenTriggers
        self.dismissedCards = dismissedCards
    }
}

/// The whole decision layer for guided first run and progressive trigger
/// cards, as pure functions so every rule is unit-tested on the host.
public enum CaptureOnboardingPolicy {
    /// Cards only appear once the user is fluent with the basics.
    public static let dictationsBeforeTriggerCards = 3

    /// The first-run test dictation stops itself after this long.
    public static let testDictationLimit: TimeInterval = 20

    /// The order cards are offered in; at most one is ever shown.
    public static let cardOrder: [CaptureTrigger] = [.control, .shortcut, .keyboard]

    /// Triggers that give the user the same thing — a press that records
    /// without opening the app. One working one is enough.
    public static let handsFreeTriggers: Set<CaptureTrigger> = [.control, .shortcut]

    /// A dictation only counts when text really came back. A cancelled run, a
    /// silent room or a failed provider must never mark a trigger as working.
    public static func isProvenTranscript(_ transcript: String) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Folds a finished dictation into the state. The transcript is the only
    /// evidence accepted: no transcript, no progress and no proven trigger.
    public static func recordingDictation(
        _ state: CaptureOnboardingState,
        trigger: CaptureTrigger,
        transcript: String
    ) -> CaptureOnboardingState {
        guard self.isProvenTranscript(transcript) else { return state }
        var next = state
        next.successfulDictations += 1
        next.provenTriggers.insert(trigger)
        return next
    }

    /// The single card to offer right now, or `nil` for "say nothing".
    public static func offeredCard(
        state: CaptureOnboardingState,
        hardware: CaptureHardwareProfile
    ) -> CaptureTrigger? {
        guard state.firstRunCompleted else { return nil }
        guard state.successfulDictations >= self.dictationsBeforeTriggerCards else { return nil }
        return self.cardOrder.first { self.isCardEligible($0, state: state, hardware: hardware) }
    }

    /// Records a dismissal. Dismissing a card retires it for good.
    public static func dismissingCard(
        _ state: CaptureOnboardingState,
        trigger: CaptureTrigger
    ) -> CaptureOnboardingState {
        var next = state
        next.dismissedCards.insert(trigger)
        return next
    }

    /// Marks the first-run sheet finished. The sheet's test dictation is
    /// recorded by the ordinary completion path, so this never folds a
    /// transcript in itself and can never double-count one.
    public static func completingFirstRun(_ state: CaptureOnboardingState) -> CaptureOnboardingState {
        var next = state
        next.firstRunCompleted = true
        return next
    }

    /// Whether the first-run sheet should be presented on this launch.
    public static func shouldPresentFirstRun(state: CaptureOnboardingState) -> Bool {
        !state.firstRunCompleted
    }

    static func isCardEligible(
        _ trigger: CaptureTrigger,
        state: CaptureOnboardingState,
        hardware: CaptureHardwareProfile
    ) -> Bool {
        guard hardware.supports(trigger) else { return false }
        guard !state.provenTriggers.contains(trigger) else { return false }
        guard !state.dismissedCards.contains(trigger) else { return false }
        guard self.handsFreeTriggers.contains(trigger) else { return true }
        // Already has a working hands-free press: do not sell a second one.
        return state.provenTriggers.isDisjoint(with: self.handsFreeTriggers)
    }
}

/// Maps a raw device identifier (`uname`'s `machine`, or
/// `SIMULATOR_MODEL_IDENTIFIER`) to whether the hardware has an Action Button.
///
/// There is no API for this, so the mapping is explicit: iPhone 15 Pro and Pro
/// Max (`iPhone16,1` / `iPhone16,2`) introduced the button, and every iPhone
/// generation from `iPhone17,*` onwards ships it on all models. Anything the
/// table does not recognise — iPad, iPod, a future non-iPhone — is treated as
/// not having one, so the copy never promises a button the user cannot find.
public enum ActionButtonHardware {
    static let firstGenerationWithButtonOnEveryModel = 17
    static let proModelsWithButton: Set<String> = ["iPhone16,1", "iPhone16,2"]

    public static func hasActionButton(deviceIdentifier: String) -> Bool {
        guard let generation = self.iPhoneGeneration(from: deviceIdentifier) else { return false }
        if generation >= self.firstGenerationWithButtonOnEveryModel { return true }
        return self.proModelsWithButton.contains(deviceIdentifier)
    }

    /// `true` for any iPhone identifier, which is also the Back Tap gate:
    /// Back Tap exists on every iPhone that can run this app, and on no iPad.
    public static func isIPhone(deviceIdentifier: String) -> Bool {
        self.iPhoneGeneration(from: deviceIdentifier) != nil
    }

    static func iPhoneGeneration(from identifier: String) -> Int? {
        guard identifier.hasPrefix("iPhone") else { return nil }
        let digits = identifier.dropFirst("iPhone".count).prefix { $0.isNumber }
        return Int(digits)
    }
}
