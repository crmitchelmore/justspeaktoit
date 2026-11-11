import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSelfTest
import CLinuxSupport

/// Routes GTK events (on the GTK thread) and shortcut presses (on the X11 or
/// portal thread) to the shared controller, in the same order-preserving
/// structures the Windows host uses.
final class LinuxEventContext: DesktopNativeEventHolder, @unchecked Sendable {
    let controller: LinuxAppController
    let smokeTest: Bool
    var smokeTestFailure: Error?
    /// Runs off the GTK thread once the window is ready, then closes it.
    var windowCheck: (@Sendable () throws -> Void)?
    /// With --ui-screenshots: loads the sample History, then saves every page here.
    var screenshotDirectory: String?
    var needsSetupAtLaunch = false
    private let historyEvents: DesktopEventDispatcher<DesktopHistoryEvent>
    private let searches: DesktopEventDispatcher<String>
    private let copies: DesktopTranscriptCopyDispatcher
    private let issueTaskLock = NSLock()
    private var issueTasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    private let settings = DesktopSettingsQueue()
    private let lock = NSLock()
    private var readyTask: Task<Void, Never>?
    private var shortcutTail: Task<Void, Never>?
    let shortcuts: LinuxShortcuts
    let globalActionShortcuts = LinuxGlobalActionShortcuts()
    let automation: LinuxAutomationSwitch
    let apiKeys = DesktopAPIKeyRequests()
    let historyPaste = DesktopHistoryPasteAdmission()
    private(set) var gestures: LinuxShortcutGestures!
    lazy var microphones = LinuxMicrophoneMonitor(controller: controller)
    /// General > System resources in use; started with the microphone monitor it probes through.
    lazy var systemResources = LinuxSystemResources.makeMonitor()
    /// Set before the window opens, when iCloud sync is configured.
    var cloudSync: LinuxCloudSync?
    /// Sidebar settings search; read and written on the GTK main thread only.
    lazy var settingsSearch = DesktopSettingsSearchSession(platform: .linux)
    /// The context every native window callback receives. It retains this
    /// holder until shutdown unregisters it; later callbacks then do nothing.
    private(set) var callbacks: NativeCallbackContext<LinuxEventContext>!
    var callbackContext: UnsafeMutableRawPointer { callbacks.pointer }

    init(controller: LinuxAppController, smokeTest: Bool) {
        self.controller = controller
        self.smokeTest = smokeTest
        self.shortcuts = LinuxShortcuts()
        self.automation = LinuxAutomationSwitch(controller: controller)
        defer {
            gestures = LinuxShortcutGestures(style: .pressToToggle) { [weak self] request in
                guard let self else { return }
                await self.ready?.value
                guard jsti_api_keys_is_open() == 0 || request.input == .gesture(.holdEnd) else { return }
                await controller.admitShortcut(request)
            }
        }
        self.searches = DesktopEventDispatcher { query in await controller.searchHistory(query) }
        self.copies = DesktopTranscriptCopyDispatcher { text, variant in
            await controller.copyTranscript(text, variant: variant)
        }
        self.historyEvents = Self.makeHistoryEvents(controller)
        callbacks = NativeCallbackContext(self)
    }

    /// Persist settings in UI event order; shutdown drains these.
    func enqueueSettings(_ action: @escaping @Sendable () async -> Void) { settings.submit(action) }
    var currentSettingsTask: Task<Void, Never>? { settings.current }
    func finishSettings() async { await settings.drain() }

    func pasteLastHistory(lifetime: DesktopShortcutListenerLifetime? = nil) {
        guard let request = historyPaste.begin() else {
            LinuxHostPlatform.update(
                "History paste is already pending or the app is closing. No new target was captured."
            )
            return
        }
        let target = Self.captureTarget(includeObservation: false)
        let controller = controller
        let deliver = {
            self.enqueueSettings {
                defer { request.finish() }
                await controller.pasteLastHistoryItem(target: target, request: request)
            }
        }
        if let lifetime {
            if !lifetime.admitCallback(deliver) { request.finish() }
        } else { deliver() }
    }

    /// Text output as of this event in settings order, however late the
    /// recording task runs.
    func recordingSettings(
        modelIndex: Int? = nil, target: LinuxInsertionTarget? = nil
    ) -> Task<LinuxRecordingSettings, Never> {
        let controller = controller
        return settings.read {
            let index: Int
            if let modelIndex, modelIndex >= 0 { index = modelIndex } else {
                index = await controller.selectedIndex()
            }
            return LinuxRecordingSettings(
                modelIndex: index, deviceID: await controller.selectedMicrophone(),
                profile: await controller.captureProfile(modelIndex: index, executablePath: target?.executablePath),
                textOutput: await controller.textOutputOptions()
            )
        }
    }

    func markReady(_ task: Task<Void, Never>) { lock.withLock { readyTask = task } }
    private var ready: Task<Void, Never>? { lock.withLock { readyTask } }

    /// A shortcut, `--toggle` or the app action. The target is captured now,
    /// before anything else can take focus; toggles run one at a time.
    func shortcutToggle(
        modelIndex: Int?, deviceID: String?, lifetime: DesktopShortcutListenerLifetime? = nil
    ) {
        guard jsti_action_shortcuts_editor_is_open() == 0, jsti_api_keys_is_open() == 0 else {
            LinuxHostPlatform.update("Close the shortcut or API Keys editor before recording.")
            return
        }
        let target = LinuxEventContext.captureTarget()
        let deliver = {
            let selection = self.recordingSettings(modelIndex: modelIndex, target: target)
            let controller = self.controller
            let ready = self.ready
            self.lock.withLock {
                let previous = self.shortcutTail
                self.shortcutTail = Task {
                    await previous?.value
                    await ready?.value
                    let saved = await selection.value
                    guard jsti_api_keys_is_open() == 0 else { return }
                    await controller.admitCaptured(
                        target: target, modelIndex: saved.modelIndex, deviceID: deviceID ?? saved.deviceID,
                        textOutput: saved.textOutput, profile: saved.profile, trigger: .press
                    )
                }
            }
        }
        if let lifetime { lifetime.admitCallback(deliver) } else { deliver() }
    }

    func drainShortcuts() async {
        await lock.withLock { shortcutTail }?.value
        await gestures.drain()
    }

    /// A global shortcut press or release from the X11 or portal thread. The
    /// target and text output are captured at the press.
    func shortcutKey(pressed: Bool, lifetime: DesktopShortcutListenerLifetime) {
        guard pressed else {
            lifetime.admitCallback { gestures.keyUp() }
            return
        }
        guard jsti_action_shortcuts_editor_is_open() == 0, jsti_api_keys_is_open() == 0 else { return }
        let target = Self.captureTarget()
        let shouldWarmMicrophone = !smokeTest && gestures.currentStyle != .pressToToggle
        lifetime.admitCallback {
            let selection = recordingSettings(target: target)
            if shouldWarmMicrophone {
                let controller = controller
                Task { await controller.warmMicrophoneForShortcutPress() }
            }
            gestures.keyDown(
                target: target, textOutput: Task { await selection.value.textOutput }, selection: selection
            )
        }
    }

    /// Applies a saved or newly chosen behaviour to the gestures and the window.
    func applyShortcutStyle(_ hotKey: LinuxHotKeySettings) {
        gestures.configure(style: hotKey.activation)
        let index = LinuxHotKeySettings.styles.firstIndex(of: hotKey.activation) ?? 0
        _ = jsti_window_set_shortcut_style(Int32(index))
    }

    /// X11 reports the focused window; Wayland hides it, so the paste goes to
    /// whatever is focused at delivery, never to this app's own window.
    /// History paste must not consume the one-shot correction-learning target.
    static func captureTarget(includeObservation: Bool = true) -> LinuxInsertionTarget? {
        switch LinuxHostPlatform.session.displayServer {
        case .x11:
            if includeObservation { return LinuxX11.captureTarget() }
            do {
                return try LinuxX11.captureTargetChecked()
            } catch {
                LinuxHostPlatform.update("Could not capture the paste target: \(error.localizedDescription)")
                return nil
            }
        case .wayland:
            return LinuxInsertionTarget(
                kind: .focusedApplication,
                observationalTarget: includeObservation ? LinuxAtspiTarget.captureAdmitted() : nil
            )
        case .unknown: return nil
        }
    }

    func copyDisplayed() {
        let variant = LinuxWindow.displayedTranscriptVariant()
        do {
            copies.submit(try LinuxWindow.displayedTranscript(), variant: variant)
        } catch { LinuxHostPlatform.update(error.localizedDescription) }
    }

    func selectHistory(_ identifier: String) { historyEvents.submit(.selection(identifier)) }

    func selectVersion(_ variant: DesktopTranscriptVariant, identifier: String) {
        historyEvents.submit(.version(identifier, variant))
    }

    /// Play/Pause, Stop and Read aloud join the selection order: a click on a
    /// newly selected row reaches it after that selection, and Stop reaches
    /// the host after the clicks before it, never before them.
    func submitHistoryPlayback(_ event: DesktopHistoryEvent) { historyEvents.submit(event) }

    func search(_ query: String) { searches.submit(query) }

    /// Register before a task can finish; completion removes only its operation.
    func issueTask(ticket: UUID, operation: @escaping @Sendable () async -> Void) {
        self.issueTaskLock.withLock {
            let identifier = UUID()
            let task = Task {
                await operation()
                self.issueTaskLock.withLock {
                    self.issueTasks[ticket]?[identifier] = nil
                    if self.issueTasks[ticket]?.isEmpty == true { self.issueTasks[ticket] = nil }
                }
            }
            self.issueTasks[ticket, default: [:]][identifier] = task
        }
    }

    /// Native Close invokes cancellation synchronously before actor retirement.
    /// The shared export handler retires its lease before a later store admission.
    func cancelIssueTasks(ticket: UUID) {
        let tasks = self.issueTaskLock.withLock { self.issueTasks.removeValue(forKey: ticket) }
        tasks?.values.forEach { $0.cancel() }
    }
}
