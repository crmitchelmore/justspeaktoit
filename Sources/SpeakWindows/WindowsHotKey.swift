import Foundation
import SpeakCore
import SpeakWindowsPlatform
import CWindowsSupport

/// The persisted global shortcut. Raw values keep a settings file written by a
/// newer build readable: an unknown style falls back to the Windows default.
struct WindowsHotKeySettings: Codable, Equatable, Sendable {
    static let alt: UInt32 = 0x1, control: UInt32 = 0x2, shift: UInt32 = 0x4
    static let space: UInt32 = 0x20

    var modifiers: UInt32 = control | alt
    var virtualKey: UInt32 = space
    var style: String = HotKeyActivationStyle.windowsDefault.rawValue

    var activation: HotKeyActivationStyle {
        HotKeyActivationStyle(rawValue: style).flatMap {
            HotKeyActivationStyle.windowsStyles.contains($0) ? $0 : nil
        } ?? .windowsDefault
    }

    var name: String { WindowsNative.hotKeyName(modifiers: modifiers, key: virtualKey) }

    /// What finishes a session that `trigger` started, for the status line.
    func finishHint(for trigger: HotKeySessionTrigger) -> String {
        switch trigger {
        case .hold: return "Release \(name) to finish."
        case .doubleTap: return "Tap \(name) to finish."
        case .press: return "Press \(name) to finish."
        case .other:
            return activation.togglesOnPress ? "Press \(name) to finish." : "Select Stop recording to finish."
        }
    }

    var readyHint: String {
        switch activation {
        case .pressToToggle: return "\(name) starts or stops recording."
        case .holdToRecord: return "Hold \(name) to record."
        case .doubleTapToggle: return "Double-tap \(name) to start or stop recording."
        case .holdAndDoubleTap: return "Hold \(name) to record, or double-tap it to start and stop."
        }
    }
}

extension WindowsNative {
    static func hotKeyName(modifiers: UInt32, key: UInt32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard jsti_hotkey_name(modifiers, key, &buffer, buffer.count) == 0 else { return "the shortcut" }
        return String(cString: buffer)
    }

    /// Configures the Shortcut dialog and the combination registered when the
    /// window starts. Invalid saved values fall back to the default shortcut.
    @discardableResult
    static func configureHotKey(_ settings: WindowsHotKeySettings, context: UnsafeMutableRawPointer) -> Bool {
        let styles = HotKeyActivationStyle.windowsStyles
        let names = styles.map(\.displayName)
        let descriptions = styles.map(\.summary)
        let style = Int32(styles.firstIndex(of: settings.activation) ?? 0)
        let press = Int32(styles.firstIndex(of: .pressToToggle) ?? 0)
        return withCStrings(names) { names in
            withCStrings(descriptions) { descriptions in
                jsti_window_set_hotkey(
                    settings.modifiers, settings.virtualKey, names, descriptions, styles.count, style, press,
                    hotKeyEvent, context
                ) == 0
            }
        }
    }

    private static func withCStrings<Result>(
        _ values: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> Result
    ) -> Result {
        let pointers: [UnsafeMutablePointer<CChar>] = values.map { value in
            let chars = Array(value.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
            pointer.initialize(from: chars, count: chars.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let borrowed: [UnsafePointer<CChar>?] = pointers.map { UnsafePointer($0) }
        return borrowed.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}

/// Apply from the native Shortcut dialog, on the UI thread, after the new
/// combination is registered. Gestures restart under the new style at once;
/// saving joins the settings queue like every other setting.
func hotKeyEvent(_ modifiers: UInt32, _ key: UInt32, _ style: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let styles = HotKeyActivationStyle.windowsStyles
    guard styles.indices.contains(Int(style)) else { return }
    let settings = WindowsHotKeySettings(modifiers: modifiers, virtualKey: key, style: styles[Int(style)].rawValue)
    holder.hotKeys.configure(style: settings.activation)
    holder.enqueueSettings {
        await holder.controller.saveHotKey(settings)
        let saved = await holder.controller.hotKeySettings()
        if !WindowsNative.configureHotKey(saved, context: Unmanaged.passUnretained(holder).toOpaque()) {
            WindowsNative.update("The saved shortcut could not be shown. Reopen Keyboard shortcut and try again.")
        }
    }
}

/// Shortcut gesture bookkeeping, in the monotonic clock of recognition.
struct WindowsHotKeySessionState {
    var lastDoubleTap: TimeInterval = -.infinity
    /// Starts recognised before this ended while a shortcut stop was finishing.
    var startsAfter: TimeInterval = 0
}

/// One recognised shortcut input with everything captured at its key press.
struct WindowsHotKeyRequest: Sendable {
    let input: HotKeySessionPolicy.Input
    let style: HotKeyActivationStyle
    /// Monotonic seconds when the gesture was recognised.
    let recognisedAt: TimeInterval
    let target: WindowsInsertionTarget?
    let textOutput: Task<WindowsTextOutputOptions, Never>
    let modelIndex: Int
    let deviceID: String
}

/// Classifies shortcut presses and releases with the shared gesture machine.
/// Every method runs on the native UI thread, which owns the machine and its
/// one deadline timer. Requests reach the controller one at a time in
/// recognition order, so a release never overtakes the start it ends.
final class WindowsHotKeyGestures: @unchecked Sendable {
    private var machine = HotKeyGestureMachine()
    private(set) var style: HotKeyActivationStyle = .windowsDefault
    private var target: WindowsInsertionTarget?
    private var textOutput: Task<WindowsTextOutputOptions, Never>?
    private var modelIndex = 0
    private var deviceID = ""
    private let clock: () -> TimeInterval
    private let armDeadline: (Int32) -> Void
    private let deliver: @Sendable (WindowsHotKeyRequest) async -> Void
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    init(
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        armDeadline: @escaping (Int32) -> Void = { _ = jsti_window_set_hotkey_deadline($0) },
        deliver: @escaping @Sendable (WindowsHotKeyRequest) async -> Void
    ) {
        self.clock = clock
        self.armDeadline = armDeadline
        self.deliver = deliver
    }

    /// A style change forgets partial gestures and ends a hold in progress,
    /// because its release will no longer be reported under the old style.
    func configure(style: HotKeyActivationStyle) {
        let ended = machine.reset()
        armDeadline(-1)
        submit(ended)
        self.style = style
    }

    func keyDown(
        target: WindowsInsertionTarget?, textOutput: Task<WindowsTextOutputOptions, Never>,
        modelIndex: Int, deviceID: String
    ) {
        self.target = target
        self.textOutput = textOutput
        self.modelIndex = modelIndex
        self.deviceID = deviceID
        submit(machine.keyDown(at: clock()))
    }

    func keyUp() { submit(machine.keyUp(at: clock())) }

    func deadlineReached() { submit(machine.deadlineReached(at: clock())) }

    /// Waits for every request already handed to the controller.
    func drain() async { await lock.withLock { tail }?.value }

    private func submit(_ gestures: [HotKeyGestureMachine.Gesture]) {
        let now = clock()
        if let deadline = machine.deadline {
            let milliseconds = max(0, ((deadline.time - now) * 1_000).rounded(.up))
            armDeadline(Int32(min(milliseconds, Double(Int32.max))))
        } else {
            armDeadline(-1)
        }
        guard let textOutput, !gestures.isEmpty else { return }
        for gesture in gestures {
            let request = WindowsHotKeyRequest(
                input: .gesture(gesture), style: style, recognisedAt: now, target: target,
                textOutput: textOutput, modelIndex: modelIndex, deviceID: deviceID
            )
            let deliver = deliver
            lock.withLock {
                let previous = tail
                tail = Task {
                    await previous?.value
                    await deliver(request)
                }
            }
        }
    }
}

extension WindowsAppController {
    func hotKeySettings() -> WindowsHotKeySettings { settings.hotKey ?? .init() }

    func saveHotKey(_ hotKey: WindowsHotKeySettings) {
        guard !closed else { return }
        var changed = settings
        changed.hotKey = hotKey
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            guard !busy, recording == nil else { return }
            update("Keyboard shortcut saved. \(hotKey.readyHint)")
        } catch {
            update("The shortcut works until you close the app, but could not be saved: \(error.localizedDescription)")
        }
    }

    /// Applies the shared macOS session rules to one recognised gesture. A
    /// gesture may stop only the kind of session it started, and a start
    /// recognised while an earlier shortcut stop was still finishing is stale.
    func hotKey(_ request: WindowsHotKeyRequest) async {
        guard !closed else { return }
        if case .gesture(.doubleTap) = request.input {
            let interval = request.recognisedAt - hotKeySession.lastDoubleTap
            guard interval >= HotKeyGestureTiming.doubleTapCommandInterval else { return }
            hotKeySession.lastDoubleTap = request.recognisedAt
        }
        guard let command = HotKeySessionPolicy.command(
            for: request.input, style: request.style, active: recording?.trigger
        ) else { return }
        switch command {
        case .start(let trigger):
            guard recording == nil, !busy, request.recognisedAt >= hotKeySession.startsAfter else { return }
            await toggle(
                target: request.target, modelIndex: request.modelIndex, deviceID: request.deviceID,
                targetExecutablePath: request.target?.executablePath, textOutput: await request.textOutput.value,
                trigger: trigger
            )
        case .stop:
            guard recording != nil, !busy else { return }
            await toggle(
                target: request.target, modelIndex: request.modelIndex, deviceID: request.deviceID,
                targetExecutablePath: request.target?.executablePath, textOutput: await request.textOutput.value
            )
            hotKeySession.startsAfter = ProcessInfo.processInfo.systemUptime
        }
    }
}
