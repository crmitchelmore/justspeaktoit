import Foundation
import CWindowsSupport
import SpeakCore
import SpeakDesktopHost

/// Hooks for pages built elsewhere, set before the window opens.
final class WindowsOnboardingHooks: @unchecked Sendable {
    static let shared = WindowsOnboardingHooks()
    private let lock = NSLock()
    private var apiKeys: ((WindowsEventContext) -> Bool)?

    /// Opens the API Keys page on the UI thread. Returns false, or is unset,
    /// to fall back to the Transcription page, where a model's key is saved.
    var openAPIKeys: ((WindowsEventContext) -> Bool)? {
        get { lock.withLock { apiKeys } }
        set { lock.withLock { apiKeys = newValue } }
    }
}

/// The first-run guide (the Mac's OnboardingView) on Windows. SpeakCore's
/// DesktopOnboardingStep owns the steps and wording; the native window shows
/// one page at a time and reports its buttons here.
enum WindowsOnboarding {
    static func code(_ action: DesktopOnboardingAction) -> Int32 {
        let native = switch action {
        case .openMicrophoneSettings: JSTI_GUIDE_ACTION_MICROPHONE_PRIVACY
        case .chooseMicrophone: JSTI_GUIDE_ACTION_MICROPHONE_PICKER
        case .chooseTextOutput: JSTI_GUIDE_ACTION_TEXT_OUTPUT
        case .chooseRemoteProvider: JSTI_GUIDE_ACTION_HOST_API_KEYS
        case .downloadLocalModel: JSTI_GUIDE_ACTION_LOCAL_MODELS
        case .chooseShortcut: JSTI_GUIDE_ACTION_SHORTCUT
        case .testDictation: JSTI_GUIDE_ACTION_TEST_DICTATION
        case .openPostProcessing: JSTI_GUIDE_ACTION_POST_PROCESSING
        case .openPermissions: JSTI_GUIDE_ACTION_PERMISSIONS
        }
        return Int32(native.rawValue)
    }

    static func index(_ step: DesktopOnboardingStep) -> Int32 {
        Int32(DesktopOnboardingStep.allCases.firstIndex(of: step) ?? 0)
    }

    static func step(_ index: Int32) -> DesktopOnboardingStep? {
        let steps = DesktopOnboardingStep.allCases
        return steps.indices.contains(Int(index)) ? steps[Int(index)] : nil
    }

    /// The step's live state: what is set up already, or what still blocks it.
    static func status(_ step: DesktopOnboardingStep, holder: WindowsEventContext) async -> String {
        let controller = holder.controller
        let system = await Task.detached { WindowsSystemPermissions.read() }.value
        let microphone = WindowsPermissions.microphone(system).item
        switch step {
        case .welcome:
            let method = await controller.textOutputOptions().method
            let items = [microphone, WindowsPermissions.insertion(method).item]
            return DesktopPermissionSummary.blockingMessage(items) ?? ""
        case .microphone: return "\(microphone.status.label): \(microphone.detail)"
        case .textInsertion:
            let insertion = WindowsPermissions.insertion(await controller.textOutputOptions().method).item
            let elevation = WindowsPermissions.elevation(system).item
            return insertion.detail + (elevation.status == .warning ? " \(elevation.detail)" : "")
        case .transcriptionRoute: return await controller.onboardingRouteSummary().text
        case .hotkeyPractice: return await controller.onboardingShortcutHint()
        case .postProcessing: return ""
        case .done:
            let route = await controller.onboardingRouteSummary()
            return route.ready ? await controller.onboardingShortcutHint() : route.text
        }
    }

    /// Shows a step with its status, after the settings before it.
    static func open(_ step: DesktopOnboardingStep, holder: WindowsEventContext) async {
        show(step, status: await status(step, holder: holder))
    }

    static func show(_ step: DesktopOnboardingStep, status: String) {
        let actions = Array(step.actions.prefix(3))
        let titles = (0..<3).map { $0 < actions.count ? actions[$0].title : "" }
        let codes = (0..<3).map { $0 < actions.count ? code(actions[$0]) : Int32(JSTI_GUIDE_ACTION_NONE.rawValue) }
        let result = withCStrings([step.title, step.progress, step.detail, status] + titles) { text -> Int32 in
            var page = JSTIGuidePage()
            page.step = index(step)
            page.title = text[0]
            page.progress = text[1]
            page.detail = text[2]
            page.status = text[3]
            page.first_title = text[4]
            page.second_title = text[5]
            page.third_title = text[6]
            page.first_action = codes[0]
            page.second_action = codes[1]
            page.third_action = codes[2]
            page.has_previous = step.previous == nil ? 0 : 1
            page.is_last = step.next == nil ? 1 : 0
            page.is_optional = step.isOptional ? 1 : 0
            return jsti_guide_set_page(&page)
        }
        if result != 0 { WindowsNative.update("Could not show the setup guide.") }
    }

    static func refreshStatus(_ step: DesktopOnboardingStep, holder: WindowsEventContext) async {
        let text = await status(step, holder: holder)
        _ = text.withCString { jsti_guide_set_status(index(step), $0) }
    }

    /// Use a provider key: the API Keys page when one is wired, otherwise the
    /// Transcription page, where the selected model's key is saved.
    static func openAPIKeys(step: DesktopOnboardingStep, holder: WindowsEventContext) {
        if WindowsOnboardingHooks.shared.openAPIKeys?(holder) == true { return }
        _ = jsti_window_show_page(Int32(JSTI_PAGE_TRANSCRIPTION))
        let hint = "Choose a remote model on the Transcription page and save its API key there, then come back here."
        _ = hint.withCString { jsti_guide_set_status(index(step), $0) }
    }
}

/// A guide button on the UI thread. Navigation and completion run in
/// settings order, so a choice applied in a settings dialog is shown.
func guideEvent(_ command: Int32, _ step: Int32, _ value: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let controller = holder.controller
    let shown = WindowsOnboarding.step(step)
    switch command {
    case Int32(JSTI_GUIDE_COMMAND_OPENED.rawValue):
        holder.enqueueSettings {
            await WindowsOnboarding.open(await controller.onboardingState().resumeStep, holder: holder)
        }
    case Int32(JSTI_GUIDE_COMMAND_NEXT.rawValue), Int32(JSTI_GUIDE_COMMAND_BACK.rawValue):
        let forward = command == Int32(JSTI_GUIDE_COMMAND_NEXT.rawValue)
        guard let target = forward ? shown?.next : shown?.previous else { return }
        holder.enqueueSettings {
            await controller.recordOnboardingStep(target)
            await WindowsOnboarding.open(target, holder: holder)
        }
    case Int32(JSTI_GUIDE_COMMAND_SKIP.rawValue), Int32(JSTI_GUIDE_COMMAND_FINISH.rawValue):
        holder.enqueueSettings {
            await controller.completeOnboarding()
            let hint = await controller.onboardingShortcutHint()
            WindowsNative.update("Setup is complete; run it again from About. \(hint)")
        }
    case Int32(JSTI_GUIDE_COMMAND_ACTION.rawValue):
        guard let shown else { return }
        if value == Int32(JSTI_GUIDE_ACTION_HOST_API_KEYS.rawValue) {
            return WindowsOnboarding.openAPIKeys(step: shown, holder: holder)
        }
        holder.enqueueSettings { await WindowsOnboarding.refreshStatus(shown, holder: holder) }
    default: break
    }
}

extension WindowsEventContext {
    func configureGuide() {
        _ = jsti_guide_configure(guideEvent, Unmanaged.passUnretained(self).toOpaque())
    }

    /// The first launch opens the guide once the window is ready.
    func openGuideIfNeeded() async {
        if await controller.needsOnboarding() { jsti_window_request_guide() }
    }
}
