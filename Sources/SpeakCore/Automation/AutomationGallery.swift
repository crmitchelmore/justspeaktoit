import Foundation

// The Shortcuts gallery (issue #1015): the recipes worth building, described
// once, rendered in the app and in `Docs/automation.md`.
//
// Data rather than prose in a view, for one reason: **a gallery entry that
// does not work is worse than no entry.** Every step that runs one of this
// app's actions names it as an ``AutomationAction`` case, and
// `AutomationGalleryIntentTests` fails the build if any case stops matching a
// shipped App Intent's title. A recipe cannot survive a rename of the action
// it depends on.
//
// Steps that name a *system* action (Apple's "Create Note", "Send Message")
// are plain text on purpose: this app cannot assert those exist, and claiming
// otherwise would be the same lie in a different place. The gallery says which
// steps are ours and which are Apple's, and never ships an installable
// `.shortcut` file — an unsigned recipe that fails to install teaches the user
// the feature is broken.

/// An action this app contributes to Shortcuts.
///
/// The raw value is the action's title exactly as Shortcuts shows it, which is
/// what the user searches for, so it is also the string the gallery renders.
public enum AutomationAction: String, CaseIterable, Sendable {
    case dictate = "Dictate"
    case startRecording = "Start Recording"
    case toggleRecording = "Toggle Recording"
    case stopRecording = "Stop Recording"
    case stopDictationAndGetText = "Stop Dictation and Get Text"
    case transcribeAudioFile = "Transcribe Audio File"
    case polishText = "Polish Text"
    case getLastTranscription = "Get Last Transcription"

    public var title: String { rawValue }

    /// Whether the action hands a value to the next step. The gallery uses it
    /// to explain why a step can be chained, and it is the property #1015 is
    /// really about: before this work only two actions returned anything.
    public var returnsText: Bool {
        switch self {
        case .dictate, .stopDictationAndGetText, .transcribeAudioFile,
             .polishText, .getLastTranscription:
            return true
        case .startRecording, .toggleRecording, .stopRecording:
            return false
        }
    }
}

/// One step of a recipe: either one of ours, or one of Apple's.
public struct AutomationRecipeStep: Equatable, Sendable {
    /// Set when the step runs an action from this app.
    public let action: AutomationAction?
    /// Set instead when the step runs a system or third-party action, named as
    /// the user will find it.
    public let systemAction: String?
    /// What to set on the step, or why it is there. Empty when the step needs
    /// no explanation.
    public let detail: String
    /// True when the step belongs to a *second* shortcut rather than
    /// continuing the previous one — the push-to-talk shape, where one
    /// trigger starts and another finishes. It is what stops the gallery
    /// implying a value flows from the step before it, when in fact nothing
    /// can: the two shortcuts run minutes apart.
    public let startsNewShortcut: Bool

    public init(action: AutomationAction, detail: String = "", startsNewShortcut: Bool = false) {
        self.action = action
        self.systemAction = nil
        self.detail = detail
        self.startsNewShortcut = startsNewShortcut
    }

    public init(systemAction: String, detail: String = "", startsNewShortcut: Bool = false) {
        self.action = nil
        self.systemAction = systemAction
        self.detail = detail
        self.startsNewShortcut = startsNewShortcut
    }

    public var title: String { action?.title ?? systemAction ?? "" }

    /// True when the step is one this app ships and can be held to a test.
    public var isAppAction: Bool { action != nil }
}

public struct AutomationRecipe: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// One line: what the user gets, not how it works.
    public let summary: String
    public let steps: [AutomationRecipeStep]
    /// Anything the recipe needs that the user may not have. Shown before the
    /// steps so nobody builds a recipe that cannot run for them.
    public let requirements: [String]
    /// SF Symbol for the gallery row.
    public let systemImage: String

    public init(
        id: String,
        title: String,
        summary: String,
        steps: [AutomationRecipeStep],
        requirements: [String] = [],
        systemImage: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.steps = steps
        self.requirements = requirements
        self.systemImage = systemImage
    }

    /// The app actions this recipe depends on.
    public var appActions: [AutomationAction] { steps.compactMap(\.action) }
}

public enum AutomationGallery {
    /// The shipped recipes.
    ///
    /// Kept short on purpose. Each one exists because the app currently makes
    /// the journey worse than it needs to be, and each is built only from
    /// actions that are covered by tests.
    public static let recipes: [AutomationRecipe] = [
        AutomationRecipe(
            id: "dictate-to-note",
            title: "Dictate straight into a note",
            summary: "One press. Speak, stop speaking, and the text is appended to a note "
                + "without the app ever coming to the front.",
            steps: [
                AutomationRecipeStep(
                    action: .dictate,
                    detail: "Leave Destination unset to use your Settings destination. "
                        + "Raise Pause Length if it finishes while you are still thinking."
                ),
                AutomationRecipeStep(
                    systemAction: "Append to Note",
                    detail: "Pass the Dictate action's text. \"Create Note\" works the same way "
                        + "if you want a new note each time."
                )
            ],
            requirements: ["iOS 18 or later for the Dictate action."],
            systemImage: "note.text"
        ),
        AutomationRecipe(
            id: "dictate-polished-reminder",
            title: "Dictate a tidied-up reminder",
            summary: "Speak a messy thought and get a clean one-line reminder, with the "
                + "clean-up done by your own post-processing model.",
            steps: [
                AutomationRecipeStep(action: .dictate),
                AutomationRecipeStep(
                    action: .polishText,
                    detail: "Custom Prompt: \"Rewrite this as one short reminder title. "
                        + "Reply with the title only.\""
                ),
                AutomationRecipeStep(systemAction: "Add New Reminder")
            ],
            requirements: [
                "iOS 18 or later for the Dictate action.",
                "A post-processing model that runs here: Apple's on-device model needs no key; "
                    + "anything else needs an OpenRouter key in Settings → API Keys."
            ],
            systemImage: "checklist"
        ),
        AutomationRecipe(
            id: "two-press-polished",
            title: "Two-press dictation that ends polished",
            summary: "For long dictation, where finishing on silence would cut you off. "
                + "The second shortcut waits for the polish and hands back the polished text, "
                + "so the shortcut and the clipboard agree.",
            steps: [
                AutomationRecipeStep(
                    action: .startRecording,
                    detail: "Put this in its own shortcut, bound to the Action Button or Back Tap."
                ),
                AutomationRecipeStep(
                    action: .stopDictationAndGetText,
                    detail: "In a second shortcut. Turn Wait For Polish on so the text you get "
                        + "is the polished version, not the raw one.",
                    startsNewShortcut: true
                ),
                AutomationRecipeStep(systemAction: "Copy to Clipboard", detail: "Or any action that takes text.")
            ],
            requirements: [
                "Wait For Polish only changes anything when your destination is "
                    + "Clipboard and Polish and a post-processing model is configured."
            ],
            systemImage: "hand.tap"
        ),
        AutomationRecipe(
            id: "share-sheet-transcribe",
            title: "Transcribe a recording from the Share Sheet",
            summary: "Turn a Voice Memo, an Apple Watch memo, or any audio file in Files into "
                + "text without exporting it anywhere. Your recording is read, never changed.",
            steps: [
                AutomationRecipeStep(
                    systemAction: "Receive audio from Share Sheet",
                    detail: "In the shortcut's settings, turn on Show in Share Sheet and set "
                        + "the accepted input to Files (or Media)."
                ),
                AutomationRecipeStep(
                    action: .transcribeAudioFile,
                    detail: "Pass the Shortcut Input. Set Language or Model here to override "
                        + "your Settings for this recipe only."
                ),
                AutomationRecipeStep(
                    action: .polishText,
                    detail: "Optional. Leave Custom Prompt empty for a clean-up."
                ),
                AutomationRecipeStep(systemAction: "Create Note")
            ],
            requirements: [
                "A batch transcription model your device has a key for "
                    + "(Settings → Transcription → file transcription)."
            ],
            systemImage: "square.and.arrow.up"
        ),
        AutomationRecipe(
            id: "what-did-i-just-say",
            title: "What did I just say?",
            summary: "Reads back the most recent transcript from History, whichever surface "
                + "recorded it — the Action Button, a Control, the keyboard or the app.",
            steps: [
                AutomationRecipeStep(action: .getLastTranscription),
                AutomationRecipeStep(systemAction: "Show Result", detail: "Or \"Speak Text\".")
            ],
            systemImage: "clock.arrow.circlepath"
        )
    ]

    /// Every app action at least one recipe depends on.
    public static var referencedActions: Set<AutomationAction> {
        Set(recipes.flatMap(\.appActions))
    }
}
