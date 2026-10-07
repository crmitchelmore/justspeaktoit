import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform

/// Shortcut gestures through the real classifier and controller with synthetic
/// effects and an explicit clock: no keyboard, microphone, credential or
/// network is used. Native registration, the dialog and press/release polling
/// are covered by the window smoke test.
enum WindowsHotKeySelfTest {
    static func run() async throws {
        try await checkClassifier()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSTI shortcut self-test \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try WindowsAppController(directory: root, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        do {
            try await checkSessions(controller)
        } catch {
            await controller.close()
            throw error
        }
        await controller.close()
        print("Keyboard shortcut gesture and session checks passed.")
    }

    /// Recognition order, deadline arming and a style change ending a hold.
    private static func checkClassifier() async throws {
        let clock = ManualClock()
        let log = RequestLog()
        let gestures = WindowsHotKeyGestures(
            clock: { clock.now }, armDeadline: { log.armed($0) }, deliver: { log.delivered($0) }
        )
        gestures.configure(style: .holdAndDoubleTap)
        let output = Task { WindowsTextOutputOptions() }
        func press(at time: TimeInterval) {
            clock.now = time
            gestures.keyDown(target: nil, textOutput: output, modelIndex: 0, deviceID: "")
        }
        func release(at time: TimeInterval) {
            clock.now = time
            gestures.keyUp()
        }
        press(at: 10)
        try require((349...351).contains(log.lastArmed), "a press did not arm the hold deadline (\(log.lastArmed))")
        clock.now = 10.35
        gestures.deadlineReached()
        release(at: 11)
        try require(log.lastArmed == -1, "a finished hold left a deadline armed")
        press(at: 20)
        release(at: 20.05)
        try require((399...401).contains(log.lastArmed), "a tap did not arm the single-tap deadline (\(log.lastArmed))")
        press(at: 20.2)
        release(at: 20.25)
        press(at: 30)
        clock.now = 30.35
        gestures.deadlineReached()
        gestures.configure(style: .doubleTapToggle)
        try require(gestures.style == .doubleTapToggle, "the style change was not applied")
        let expected: [HotKeyGestureMachine.Gesture] = [.holdStart, .holdEnd, .doubleTap, .holdStart, .holdEnd]
        try await waitFor("classified gestures") { log.inputs.count == expected.count }
        try require(log.inputs == expected.map { .gesture($0) }, "gestures reached the controller out of order")
        try require(log.styles.last == .holdAndDoubleTap, "the hold ended by a style change used the new style")
    }

    private static func checkSessions(_ controller: WindowsAppController) async throws {
        let batch = WindowsModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil }
        guard let model = batch else { throw selfTestFailure("the model catalogue has no batch route") }
        func send(
            _ input: HotKeySessionPolicy.Input, _ style: HotKeyActivationStyle, at time: TimeInterval? = nil
        ) async {
            await controller.hotKey(WindowsHotKeyRequest(
                input: input, style: style, recognisedAt: time ?? ProcessInfo.processInfo.systemUptime, target: nil,
                textOutput: Task { WindowsTextOutputOptions() }, modelIndex: model, deviceID: ""
            ))
        }
        // Press & Hold: taps never stop a hold; its release does.
        await send(.gesture(.holdStart), .holdToRecord)
        try await expect(controller, .hold, "holdStart did not start a hold session")
        await send(.gesture(.singleTap), .holdToRecord)
        await send(.gesture(.doubleTap), .holdToRecord)
        try await expect(controller, .hold, "a tap ended a hold session")
        await send(.gesture(.holdEnd), .holdToRecord)
        try await expect(controller, nil, "releasing did not end the hold session")

        // Double Tap: a release never ends it; a single tap does. Double taps
        // closer than the command interval are duplicates.
        try await Task.sleep(for: .milliseconds(300))
        await send(.gesture(.doubleTap), .doubleTapToggle)
        try await expect(controller, .doubleTap, "a double tap did not start a session")
        await send(.gesture(.holdEnd), .doubleTapToggle)
        await send(.gesture(.doubleTap), .doubleTapToggle)
        try await expect(controller, .doubleTap, "a release or duplicate double tap ended the session")
        try await Task.sleep(for: .milliseconds(300))
        await send(.gesture(.singleTap), .doubleTapToggle)
        try await expect(controller, nil, "a single tap did not end the double-tap session")

        // A start recognised before that shortcut stop finished is stale.
        await send(.gesture(.holdStart), .holdAndDoubleTap, at: ProcessInfo.processInfo.systemUptime - 60)
        try await expect(controller, nil, "a stale shortcut start began a recording")

        // A Record-button session belongs to the button under gesture styles.
        await controller.toggle(
            target: nil, modelIndex: model, deviceID: "", targetExecutablePath: nil,
            textOutput: WindowsTextOutputOptions()
        )
        try await expect(controller, .other, "Record did not start")
        for gesture in HotKeyGestureMachine.Gesture.allCases {
            try await Task.sleep(for: .milliseconds(300))
            await send(.gesture(gesture), .holdAndDoubleTap)
        }
        try await expect(controller, .other, "a gesture ended a session started by Record")
        await send(.press, .pressToToggle)
        try await expect(controller, nil, "press-to-toggle did not stop the session")
    }

    private static func expect(
        _ controller: WindowsAppController, _ trigger: HotKeySessionTrigger?, _ message: String
    ) async throws {
        let actual = await controller.hotKeySelfTestTrigger()
        try require(actual == trigger, "\(message) (\(actual.map(\.rawValue) ?? "idle"))")
    }
}

extension WindowsAppController {
    fileprivate func hotKeySelfTestTrigger() -> HotKeySessionTrigger? { recording?.trigger }
}

private final class ManualClock: @unchecked Sendable {
    var now: TimeInterval = 0
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [WindowsHotKeyRequest] = []
    private var deadline: Int32 = -2

    var inputs: [HotKeySessionPolicy.Input] { lock.withLock { requests.map(\.input) } }
    var styles: [HotKeyActivationStyle] { lock.withLock { requests.map(\.style) } }
    var lastArmed: Int32 { lock.withLock { deadline } }

    func armed(_ milliseconds: Int32) { lock.withLock { deadline = milliseconds } }
    func delivered(_ request: WindowsHotKeyRequest) { lock.withLock { requests.append(request) } }
}

private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw selfTestFailure(message()) }
}

private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw selfTestFailure("timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
