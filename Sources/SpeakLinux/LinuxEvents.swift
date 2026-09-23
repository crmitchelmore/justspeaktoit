import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

private enum LinuxHistoryEvent: Sendable {
    case selection(String)
    case version(String, DesktopTranscriptVariant)
}

/// Routes GTK events (on the GTK thread) and shortcut presses (on the X11 or
/// portal thread) to the shared controller, in the same order-preserving
/// structures the Windows host uses.
final class LinuxEventContext: @unchecked Sendable {
    let controller: LinuxAppController
    let smokeTest: Bool
    var smokeTestFailure: Error?
    private let historyEvents: DesktopEventDispatcher<LinuxHistoryEvent>
    private let searches: DesktopEventDispatcher<String>
    private let copies: DesktopTranscriptCopyDispatcher
    private let settings = DesktopSettingsQueue()
    private let lock = NSLock()
    private var readyTask: Task<Void, Never>?
    private var shortcutTail: Task<Void, Never>?
    let shortcuts: LinuxShortcuts

    init(controller: LinuxAppController, smokeTest: Bool) {
        self.controller = controller
        self.smokeTest = smokeTest
        self.shortcuts = LinuxShortcuts()
        self.searches = DesktopEventDispatcher { query in await controller.searchHistory(query) }
        self.copies = DesktopTranscriptCopyDispatcher { text, variant in
            await controller.copyTranscript(text, variant: variant)
        }
        self.historyEvents = DesktopEventDispatcher { event in
            switch event {
            case .selection(let identifier): await controller.selectHistory(identifier)
            case .version(let identifier, let variant):
                await controller.selectTranscriptVariant(variant, identifier: identifier)
            }
        }
    }

    /// Persist settings in UI event order; shutdown drains these.
    func enqueueSettings(_ action: @escaping @Sendable () async -> Void) { settings.submit(action) }
    var currentSettingsTask: Task<Void, Never>? { settings.current }
    func finishSettings() async { await settings.drain() }

    /// Text output as of this event in settings order, however late the
    /// recording task runs.
    func recordingTextOutput() -> Task<LinuxTextOutputOptions, Never> {
        let controller = controller
        return settings.read { await controller.textOutputOptions() }
    }

    func markReady(_ task: Task<Void, Never>) { lock.withLock { readyTask = task } }
    private var ready: Task<Void, Never>? { lock.withLock { readyTask } }

    /// A shortcut, `--toggle` or the app action. The target is captured now,
    /// before anything else can take focus; toggles run one at a time.
    func shortcutToggle(modelIndex: Int?, deviceID: String?) {
        let target = LinuxEventContext.captureTarget()
        let textOutput = recordingTextOutput()
        let controller = controller
        let ready = ready
        lock.withLock {
            let previous = shortcutTail
            shortcutTail = Task {
                await previous?.value
                await ready?.value
                let index: Int
                if let modelIndex, modelIndex >= 0 { index = modelIndex } else { index = await controller.selectedIndex() }
                let device: String
                if let deviceID { device = deviceID } else { device = await controller.selectedMicrophone() }
                await controller.toggle(
                    target: target, modelIndex: index, deviceID: device,
                    targetExecutablePath: target?.executablePath, textOutput: await textOutput.value, trigger: .press
                )
            }
        }
    }

    func drainShortcuts() async { await lock.withLock { shortcutTail }?.value }

    /// X11 reports the focused window; Wayland hides it, so the paste goes to
    /// whatever is focused at delivery, never to this app's own window.
    static func captureTarget() -> LinuxInsertionTarget? {
        switch LinuxHostPlatform.session.displayServer {
        case .x11: return LinuxX11.captureTarget()
        case .wayland: return LinuxInsertionTarget(kind: .focusedApplication)
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

    func search(_ query: String) { searches.submit(query) }
}

/// The GTK window's event callback, on the GTK main thread.
func linuxWindowEvent(_ event: Int32, _ text: UnsafePointer<CChar>?, _ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    let controller = holder.controller
    let value = text.map(String.init(cString:)) ?? ""
    let slot = Int(index)
    switch Int(event) {
    case Int(JSTI_EVENT_TOGGLE_RECORDING):
        // Record in this window: its own window is focused, so there is no
        // field to paste into. The transcript is saved and offered for Copy.
        let textOutput = holder.recordingTextOutput()
        Task {
            await controller.toggle(
                target: nil, modelIndex: slot, deviceID: value, targetExecutablePath: nil,
                textOutput: await textOutput.value
            )
        }
    case Int(JSTI_EVENT_COMMAND_TOGGLE):
        holder.shortcutToggle(modelIndex: slot, deviceID: value)
    case Int(JSTI_EVENT_IMPORT):
        let pending = holder.currentSettingsTask
        Task {
            await pending?.value
            await controller.importAudio(path: value, modelIndex: slot)
        }
    case Int(JSTI_EVENT_COPY): holder.copyDisplayed()
    case Int(JSTI_EVENT_SAVE_KEY): holder.enqueueSettings { await controller.saveKey(value, modelIndex: slot) }
    case Int(JSTI_EVENT_SELECT_MODEL): holder.enqueueSettings { await controller.selectModel(slot) }
    case Int(JSTI_EVENT_READY): linuxReady(holder)
    case Int(JSTI_EVENT_SELECT_HISTORY): holder.selectHistory(value)
    case Int(JSTI_EVENT_RETRY_HISTORY): Task { await controller.retryHistory(value) }
    case Int(JSTI_EVENT_EXPORT_HISTORY):
        // The window captured the text and version at the Export click; the
        // snapshot returns that capture while this event runs.
        do {
            let text = try LinuxWindow.displayedTranscript()
            let variant: DesktopTranscriptVariant = slot == 0 ? .processed : .original
            Task { await controller.exportHistory(text: text, variant: variant, path: value) }
        } catch { LinuxHostPlatform.update(error.localizedDescription) }
    case Int(JSTI_EVENT_OPEN_AUDIO): Task { await controller.openHistoryAudio(value) }
    case Int(JSTI_EVENT_SELECT_MICROPHONE): holder.enqueueSettings { await controller.selectMicrophone(value) }
    case Int(JSTI_EVENT_CANCEL): Task { await controller.cancelTranscription() }
    case Int(JSTI_EVENT_SEARCH_HISTORY): holder.search(value)
    case Int(JSTI_EVENT_TRANSCRIPT_VERSION):
        holder.selectVersion(slot == 1 ? .original : .processed, identifier: value)
    case Int(JSTI_EVENT_PLAYBACK_TOGGLE): Task { await controller.playbackToggle(value) }
    case Int(JSTI_EVENT_PLAYBACK_STOP): Task { await controller.playbackStop() }
    case Int(JSTI_EVENT_REFRESH_MODELS): Task { await controller.refreshModels(force: true) }
    case Int(JSTI_EVENT_TEXT_OUTPUT):
        let options = LinuxTextOutputOptions(
            method: slot == 1 ? .clipboardOnly : .paste, restoreClipboard: value == "restore"
        )
        holder.enqueueSettings {
            await controller.saveTextOutput(options)
            LinuxWindow.textOutput(await controller.textOutputOptions(), hint: holder.shortcuts.hint)
        }
    default: break
    }
}

private func linuxReady(_ holder: LinuxEventContext) {
    guard holder.smokeTest else {
        let controller = holder.controller
        holder.markReady(Task { await controller.ready() })
        holder.shortcuts.start(holder)
        return
    }
    do {
        // Capture the laid-out startup window before the self-test changes it.
        if let path = ProcessInfo.processInfo.environment["JSTI_UI_SNAPSHOT_PATH"] {
            try path.withCString { path in try LinuxNative.call { jsti_window_save_snapshot(path, $0, $1) } }
        }
        try LinuxNative.call { jsti_window_self_test($0, $1) }
    } catch { holder.smokeTestFailure = error }
    jsti_window_request_close()
}
