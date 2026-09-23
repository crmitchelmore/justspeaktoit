import Foundation
import SpeakCore
import SpeakDesktop

/// Runs the post-processing Apply through the real controller and settings
/// queue, with synthetic effects and a synthetic iCloud sync key hook: no
/// credential store, network or window is used. A typed key reaches the hook
/// trimmed and under the post-processing credential, a blank field keeps the
/// saved key, the choices land on the settings as they are once the key is
/// saved, Applies keep their order, a failed save changes no choice, and an
/// Apply that resumes after the controller closed writes nothing more.
enum WindowsPostProcessingSelfTest {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSTI post-processing self-test \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let model = DesktopPostProcessing.remoteModels.first?.id,
              case .apiKey(let identifier, _) = ModelCredentialResolver.requirement(
                  for: model, purpose: .postProcessing
              )
        else { throw failure("no remote post-processing model takes an API key") }
        try await checkTypedAndBlankKeys(PostProcessingBench.make(root, "Keys"), identifier: identifier)
        try await checkChoicesLandOnCurrentSettings(PostProcessingBench.make(root, "Current"))
        try await checkAppliesKeepTheirOrder(PostProcessingBench.make(root, "Order"))
        try await checkFailedSavesChangeNoChoice(PostProcessingBench.make(root, "Failures"))
        try await checkClosingDuringTheKeySave(PostProcessingBench.make(root, "Closing"))
        print("Post-processing key and settings checks passed.")
    }

    private static func checkTypedAndBlankKeys(_ bench: PostProcessingBench, identifier: String) async throws {
        bench.apply(enabled: true, prompt: "Tidy it.", key: "  synthetic-typed-key \n")
        await bench.settle()
        try require(bench.hook.savedValues == ["synthetic-typed-key"], "the typed key did not reach the hook trimmed")
        try require(bench.hook.savedIdentifiers == [identifier], "the typed key was saved as another credential")
        let enabled = await bench.controller.postProcessingOptions()
        try require(enabled.mode == .remote && enabled.customPrompt == "Tidy it.", "the Apply was not saved")

        bench.apply(enabled: false, prompt: "", key: "   ")
        await bench.settle()
        try require(bench.hook.savedValues.count == 1, "a blank key field replaced or removed the saved key")
        let disabled = await bench.controller.postProcessingOptions()
        try require(disabled.mode == .disabled, "an Apply with a blank key field was not saved")
        await bench.close()
    }

    /// Another writer, such as the model catalogue, saves a different setting
    /// while the key is being saved: the Apply must keep it.
    private static func checkChoicesLandOnCurrentSettings(_ bench: PostProcessingBench) async throws {
        try await bench.holdNextKeySave { bench.apply(enabled: true, prompt: "Tidy it.", key: "synthetic-typed-key") }
        let textOutput = WindowsTextOutputOptions(method: .clipboardOnly)
        await bench.controller.saveTextOutput(textOutput)
        bench.hook.gate.open()
        await bench.settle()
        await bench.close()

        let stored = try await bench.reopen()
        try require(stored.postProcessing.mode == .remote, "the Apply held at its key save was not saved")
        try require(stored.textOutput == textOutput, "the Apply overwrote a setting saved while its key was saved")
    }

    private static func checkAppliesKeepTheirOrder(_ bench: PostProcessingBench) async throws {
        try await bench.holdNextKeySave { bench.apply(enabled: true, prompt: "Earlier.", key: "synthetic-earlier-key") }
        bench.apply(enabled: false, prompt: "Later.", key: "")
        let pending = await bench.controller.postProcessingOptions()
        try require(pending == DesktopPostProcessing.Options(), "an Apply was saved before the one queued ahead of it")
        bench.hook.gate.open()
        await bench.settle()

        let options = await bench.controller.postProcessingOptions()
        try require(options.mode == .disabled && options.customPrompt == "Later.", "the later Apply did not decide")
        try require(bench.hook.savedValues == ["synthetic-earlier-key"], "the earlier Apply's key was not saved")
        await bench.close()
    }

    private static func checkFailedSavesChangeNoChoice(_ bench: PostProcessingBench) async throws {
        bench.apply(enabled: true, prompt: "Kept.", key: "")
        await bench.settle()
        let kept = await bench.controller.postProcessingOptions()

        bench.hook.failNext()
        bench.apply(enabled: false, prompt: "Refused key.", key: "synthetic-refused-key")
        await bench.settle()
        let afterRefusal = await bench.controller.postProcessingOptions()
        try require(afterRefusal == kept, "choices changed although their key could not be saved")

        bench.effects.failNextSettingsWrite()
        bench.apply(enabled: false, prompt: "Unwritten.", key: "synthetic-saved-key")
        await bench.settle()
        let afterFailedWrite = await bench.controller.postProcessingOptions()
        try require(afterFailedWrite == kept, "choices that could not be written were kept")
        try require(bench.hook.savedValues == ["synthetic-saved-key"], "the key saved before the failed write is gone")
        await bench.close()
    }

    /// Shutdown drains the settings queue before closing; if the controller
    /// closes first anyway, an Apply resuming from its key save writes nothing.
    private static func checkClosingDuringTheKeySave(_ bench: PostProcessingBench) async throws {
        try await bench.holdNextKeySave { bench.apply(enabled: true, prompt: "Too late.", key: "synthetic-late-key") }
        await bench.controller.close()
        bench.hook.gate.open()
        await bench.settle()

        let stored = try await bench.reopen()
        let untouched = stored.postProcessing == DesktopPostProcessing.Options()
        try require(untouched, "an Apply wrote after the controller closed")
    }
}

/// One controller, its settings queue and a synthetic sync key hook, in a
/// directory of its own.
private final class PostProcessingBench: @unchecked Sendable {
    struct Stored {
        let postProcessing: DesktopPostProcessing.Options
        let textOutput: WindowsTextOutputOptions
    }

    let directory: URL
    let effects: SyntheticEffects
    let hook = SyntheticKeyHook()
    let controller: WindowsAppController
    let holder: WindowsEventContext

    private init(directory: URL, effects: SyntheticEffects, controller: WindowsAppController) {
        self.directory = directory
        self.effects = effects
        self.controller = controller
        holder = WindowsEventContext(controller: controller, smokeTest: true)
    }

    static func make(_ root: URL, _ name: String) async throws -> PostProcessingBench {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let effects = SyntheticEffects()
        let controller = try WindowsAppController(directory: directory, effects: effects)
        let bench = PostProcessingBench(directory: directory, effects: effects, controller: controller)
        await controller.installCloudSync(bench.hook.hooks)
        return bench
    }

    /// Queues an Apply the way the dialog's native callback does.
    func apply(enabled: Bool, prompt: String, key: String) {
        let controller = controller
        holder.enqueueSettings {
            await controller.savePostProcessing(enabled: enabled, modelIndex: 0, prompt: prompt, key: key)
        }
    }

    /// Runs `start`, then returns once its key save is held at the hook.
    func holdNextKeySave(_ start: () -> Void) async throws {
        hook.gate.close()
        let arrivals = hook.gate.arrivals
        start()
        try await eventually("an Apply reached the sync key hook") { self.hook.gate.arrivals > arrivals }
    }

    func settle() async { await holder.finishSettings() }

    func close() async {
        await holder.finishSettings()
        await controller.close()
    }

    /// The choices on disk, as a relaunch reads them.
    func reopen() async throws -> Stored {
        let reopened = try WindowsAppController(directory: directory, effects: SyntheticEffects())
        let postProcessing = await reopened.postProcessingOptions()
        let textOutput = await reopened.textOutputOptions()
        await reopened.close()
        return Stored(postProcessing: postProcessing, textOutput: textOutput)
    }
}

/// The iCloud sync key hook, synthetic: it records each save and can hold or
/// refuse the next one. Only synthetic values pass through it.
private final class SyntheticKeyHook: @unchecked Sendable {
    let gate = SelfTestGate(open: true)
    private let lock = NSLock()
    private var values: [String] = []
    private var identifiers: [String] = []
    private var refusesNext = false

    var savedValues: [String] { lock.withLock { values } }
    var savedIdentifiers: [String] { lock.withLock { identifiers } }

    var hooks: WindowsCloudSyncHooks {
        WindowsCloudSyncHooks(saveKeyByHand: { [self] value, identifier in try await self.save(value, identifier) })
    }

    func failNext() { lock.withLock { refusesNext = true } }

    private func save(_ value: String, _ identifier: String) async throws {
        await gate.pass()
        let refuses = lock.withLock { () -> Bool in
            defer { refusesNext = false }
            return refusesNext
        }
        if refuses { throw failure("synthetic key save refusal") }
        lock.withLock {
            values.append(value)
            identifiers.append(identifier)
        }
    }
}

private func failure(_ message: String) -> WindowsNativeError {
    WindowsNativeError(message: "Post-processing self-test: \(message).")
}

private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw failure(message()) }
}

/// Polls a condition, yielding between checks, for at most ten seconds.
private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw failure("timed out waiting for \(what)") }
        await Task.yield()
    }
}
