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
    /// Runs off the GTK thread once the window is ready, then closes it.
    var windowCheck: (@Sendable () throws -> Void)?
    private let historyEvents: DesktopEventDispatcher<LinuxHistoryEvent>
    private let searches: DesktopEventDispatcher<String>
    private let copies: DesktopTranscriptCopyDispatcher
    private let settings = DesktopSettingsQueue()
    private let lock = NSLock()
    private var readyTask: Task<Void, Never>?
    private var shortcutTail: Task<Void, Never>?
    let shortcuts: LinuxShortcuts
    private(set) var gestures: LinuxShortcutGestures!
    lazy var microphones = LinuxMicrophoneMonitor(controller: controller)

    init(controller: LinuxAppController, smokeTest: Bool) {
        self.controller = controller
        self.smokeTest = smokeTest
        self.shortcuts = LinuxShortcuts()
        defer {
            gestures = LinuxShortcutGestures(style: .pressToToggle) { [weak self] request in
                guard let self else { return }
                await self.ready?.value
                // Model and microphone are the saved ones, read in settings order.
                let index = await controller.selectedIndex()
                let device = await controller.selectedMicrophone()
                await controller.shortcut(.init(
                    input: request.input, style: request.style, recognisedAt: request.recognisedAt,
                    target: request.target, targetExecutablePath: request.targetExecutablePath,
                    textOutput: request.textOutput, modelIndex: index, deviceID: device
                ))
            }
        }
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
                if let modelIndex, modelIndex >= 0 {
                    index = modelIndex
                } else {
                    index = await controller.selectedIndex()
                }
                let device: String
                if let deviceID { device = deviceID } else { device = await controller.selectedMicrophone() }
                await controller.toggle(
                    target: target, modelIndex: index, deviceID: device,
                    targetExecutablePath: target?.executablePath, textOutput: await textOutput.value, trigger: .press
                )
            }
        }
    }

    func drainShortcuts() async {
        await lock.withLock { shortcutTail }?.value
        await gestures.drain()
    }

    /// A global shortcut press or release from the X11 or portal thread. The
    /// target and text output are captured at the press.
    func shortcutKey(pressed: Bool) {
        if pressed {
            gestures.keyDown(target: Self.captureTarget(), textOutput: recordingTextOutput())
        } else {
            gestures.keyUp()
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
func linuxWindowEvent(
    _ event: Int32, _ text: UnsafePointer<CChar>?, _ index: Int32, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    let value = text.map(String.init(cString:)) ?? ""
    let slot = Int(index)
    let event = Int(event)
    if linuxSessionEvent(event, value: value, slot: slot, holder: holder) { return }
    if linuxHistoryEvent(event, value: value, slot: slot, holder: holder) { return }
    _ = linuxSettingsEvent(event, value: value, slot: slot, holder: holder)
}

/// Recording, import, copy and lifecycle events. Returns false for others.
private func linuxSessionEvent(_ event: Int, value: String, slot: Int, holder: LinuxEventContext) -> Bool {
    let controller = holder.controller
    switch event {
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
    case Int(JSTI_EVENT_READY): linuxReady(holder)
    case Int(JSTI_EVENT_CANCEL): Task { await controller.cancelTranscription() }
    case Int(JSTI_EVENT_REFRESH_MODELS): Task { await controller.refreshModels(force: true) }
    default: return false
    }
    return true
}

/// History list, export and playback events. Returns false for others.
private func linuxHistoryEvent(_ event: Int, value: String, slot: Int, holder: LinuxEventContext) -> Bool {
    let controller = holder.controller
    switch event {
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
    case Int(JSTI_EVENT_SEARCH_HISTORY): holder.search(value)
    case Int(JSTI_EVENT_TRANSCRIPT_VERSION):
        holder.selectVersion(slot == 1 ? .original : .processed, identifier: value)
    case Int(JSTI_EVENT_PLAYBACK_TOGGLE): Task { await controller.playbackToggle(value) }
    case Int(JSTI_EVENT_PLAYBACK_STOP): Task { await controller.playbackStop() }
    default: return false
    }
    return true
}

/// Settings events, applied in order. Returns false for unknown events.
private func linuxSettingsEvent(_ event: Int, value: String, slot: Int, holder: LinuxEventContext) -> Bool {
    let controller = holder.controller
    switch event {
    case Int(JSTI_EVENT_SAVE_KEY): holder.enqueueSettings { await controller.saveKey(value, modelIndex: slot) }
    case Int(JSTI_EVENT_SELECT_MODEL): holder.enqueueSettings { await controller.selectModel(slot) }
    case Int(JSTI_EVENT_SELECT_MICROPHONE): holder.enqueueSettings { await controller.selectMicrophone(value) }
    case Int(JSTI_EVENT_TEXT_OUTPUT):
        let options = LinuxTextOutputOptions(
            method: slot == 1 ? .clipboardOnly : .paste, restoreClipboard: value == "restore"
        )
        holder.enqueueSettings {
            await controller.saveTextOutput(options)
            LinuxWindow.textOutput(await controller.textOutputOptions(), hint: holder.shortcuts.hint)
        }
    case Int(JSTI_EVENT_POST_PROCESSING):
        let enabled = slot >= 0
        let model = enabled ? slot : -1 - slot
        let parts = value.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        let prompt = parts.first.map(String.init) ?? ""
        let key = parts.count > 1 ? String(parts[1]) : ""
        holder.enqueueSettings {
            await controller.savePostProcessing(enabled: enabled, modelIndex: model, prompt: prompt, key: key)
            LinuxWindow.postProcessing(await controller.postProcessingOptions())
        }
    case Int(JSTI_EVENT_SHORTCUT_STYLE):
        guard LinuxHotKeySettings.styles.indices.contains(slot) else { break }
        let hotKey = LinuxHotKeySettings(style: LinuxHotKeySettings.styles[slot].rawValue)
        holder.gestures.configure(style: hotKey.activation)
        holder.enqueueSettings { await controller.saveHotKey(hotKey) }
    default: return false
    }
    return true
}

private func linuxReady(_ holder: LinuxEventContext) {
    if let check = holder.windowCheck {
        Thread.detachNewThread {
            do { try check() } catch { holder.smokeTestFailure = error }
            jsti_window_request_close()
        }
        return
    }
    guard holder.smokeTest else {
        let controller = holder.controller
        holder.markReady(Task { await controller.ready() })
        holder.shortcuts.start(holder)
        do { try holder.microphones.start() } catch {
            LinuxHostPlatform.update("Microphone changes will not be noticed: \(error.localizedDescription)")
        }
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
