import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform
import CWindowsSupport

/// Runs the real controller, settings queue, native Apply callback and Record
/// event barrier with synthetic effects: no microphone, credentials, network,
/// clipboard or other application is used. Each recording must output with the
/// text output choice saved when it started, never a later one, and imports,
/// History retries and shutdown must never output automatically. Recordings
/// here start from this window, so they have no captured field: Copy to the
/// clipboard delivers and the inserting methods deliver nothing.
enum WindowsTextOutputSelfTest {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSTI text output self-test \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkStoredSettings(in: root)
        let workflow = try TextOutputWorkflow(directory: root.appendingPathComponent("Workflow", isDirectory: true))
        do {
            try await workflow.run()
        } catch {
            await workflow.abandon()
            throw error
        }
        print("Text output settings and recording snapshot checks passed.")
    }

    /// Settings saved before Text output existed, or edited by hand, keep the
    /// defaults, migrate unknown values as before and keep other settings.
    private static func checkStoredSettings(in root: URL) async throws {
        let prefix = #"{"model":"\#(ModelCatalog.defaultBatchTranscriptionModel)","microphoneDeviceID":"synthetic""#
        let files: [(json: String, expected: WindowsTextOutputOptions)] = [
            (prefix + "}", WindowsTextOutputOptions()),
            (prefix + #","textOutput":{}}"#, WindowsTextOutputOptions()),
            (
                prefix + #","textOutput":{"method":"telepathy","insertion":"replaceField","restoreClipboard":false}}"#,
                WindowsTextOutputOptions(insertion: .replaceField, restoreClipboard: false)
            )
        ]
        for (index, file) in files.enumerated() {
            let directory = root.appendingPathComponent("Stored \(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(file.json.utf8).write(to: directory.appendingPathComponent("settings.json"))
            let controller = try WindowsAppController(directory: directory, effects: SyntheticEffects())
            let options = await controller.textOutputOptions()
            let microphone = await controller.selectedMicrophone()
            await controller.close()
            try require(options == file.expected && microphone == "synthetic", "stored settings \(index) changed")
        }
    }
}

private final class TextOutputWorkflow {
    private let directory: URL
    private let effects: SyntheticEffects
    private let controller: WindowsAppController
    private let holder: WindowsEventContext
    private let batchIndex: Int
    private let liveIndex: Int
    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(holder).toOpaque() }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let effects = SyntheticEffects()
        let controller = try WindowsAppController(directory: directory, effects: effects)
        guard let batch = WindowsModels.all.firstIndex(where: { DesktopTranscription.provider(for: $0.id) != nil }),
              let live = WindowsModels.all.firstIndex(where: { WindowsModels.isLive($0.id) }) else {
            throw selfTestFailure("the model catalogue has no batch and live route")
        }
        self.directory = directory
        self.effects = effects
        self.controller = controller
        holder = WindowsEventContext(controller: controller, smokeTest: true)
        batchIndex = batch
        liveIndex = live
    }

    func run() async throws {
        await controller.markReadyForSelfTest()
        try WindowsNative.configureTextOutput(WindowsTextOutputOptions(), context: context)
        try await checkBatchKeepsItsStartChoice()
        try await checkLiveKeepsItsStartChoice()
        try await checkApplyBeforeRecord()
        try await checkFailedSaveKeepsSettings()
        try await checkImportAndRetryNeverOutput()
        try await checkClosingCancelsPendingOutput()
    }

    func abandon() async {
        effects.releaseAll()
        let closed = SelfTestSwitch()
        let controller = controller
        Task {
            await controller.close()
            closed.open()
        }
        try? await eventually("abandoned workflow closed") { closed.isOpen }
    }

    /// Start with Copy to the clipboard, Apply Smart while transcription is
    /// suspended, then release: this recording still copies, and the next one
    /// follows Smart.
    private func checkBatchKeepsItsStartChoice() async throws {
        await apply(WindowsTextOutputOptions(method: .clipboardOnly))
        try await start(batchIndex, "batch")
        effects.transcription.close()
        let arrivals = effects.transcription.arrivals
        let stopping = stop(batchIndex)
        try await eventually("suspended batch transcription") { self.effects.transcription.arrivals > arrivals }
        let later = WindowsTextOutputOptions(method: .smart, insertion: .replaceField)
        await apply(later)
        try await expectSaved(later, "Apply while transcribing")
        effects.transcription.open()
        await stopping.value
        try await expectCopy(SyntheticEffects.batchText, "batch recording kept its start choice")
        try await start(batchIndex, "next batch")
        await stop(batchIndex).value
        try await expectNoOutput(SyntheticEffects.batchText, "next batch recording followed the later choice")
    }

    /// The reverse on the live path: Direct insertion at start, Copy applied
    /// while the provider finalises.
    private func checkLiveKeepsItsStartChoice() async throws {
        await apply(WindowsTextOutputOptions(method: .directOnly))
        try await start(liveIndex, "live")
        effects.liveFinish.close()
        let arrivals = effects.liveFinish.arrivals
        let stopping = stop(liveIndex)
        try await eventually("suspended live finalisation") { self.effects.liveFinish.arrivals > arrivals }
        let later = WindowsTextOutputOptions(method: .clipboardOnly, restoreClipboard: false)
        await apply(later)
        try await expectSaved(later, "Apply while finalising")
        effects.liveFinish.open()
        await stopping.value
        try await expectNoOutput(SyntheticEffects.liveText, "live recording kept its start choice")
        try await start(liveIndex, "next live")
        await stop(liveIndex).value
        try await expectCopy(SyntheticEffects.liveText, "next live recording followed the later choice")
    }

    /// Record waits for an Apply queued before it, even behind a slower
    /// settings operation, and records with that choice.
    private func checkApplyBeforeRecord() async throws {
        await apply(WindowsTextOutputOptions())
        let earlier = SelfTestGate()
        holder.enqueueSettings { await earlier.pass() }
        let choice = WindowsTextOutputOptions(method: .clipboardOnly).nativeChoice
        textOutputEvent(choice.method, choice.insertion, choice.restoreClipboard, context)
        let starting = toggle(batchIndex)
        try await Task.sleep(for: .milliseconds(100))
        let waited = await !controller.selfTestState().recording
        earlier.open()
        await starting.value
        try require(waited, "Record started before the Apply queued ahead of it")
        try await expectSaved(WindowsTextOutputOptions(method: .clipboardOnly), "Apply before Record")
        let started = await controller.selfTestState().recording
        try require(started, "Record did not start after the Apply before it")
        await stop(batchIndex).value
        try await expectCopy(SyntheticEffects.batchText, "Record used the Apply before it")
    }

    /// A failed atomic write keeps every setting in memory, on disk and in the
    /// native dialog; a later save survives reopening with other settings intact.
    private func checkFailedSaveKeepsSettings() async throws {
        let kept = WindowsTextOutputOptions(method: .directOnly, insertion: .replaceField, restoreClipboard: false)
        await apply(kept)
        let file = directory.appendingPathComponent("settings.json")
        let fileBefore = try Data(contentsOf: file)
        let settingsBefore = try await controller.encodedSettings()
        effects.failNextSettingsWrite()
        await apply(WindowsTextOutputOptions(method: .clipboardOnly))
        let fileAfter = try Data(contentsOf: file)
        let settingsAfter = try await controller.encodedSettings()
        try require(fileAfter == fileBefore && settingsAfter == settingsBefore, "a failed save changed settings")
        try await expectSaved(kept, "failed save")
        let saved = WindowsTextOutputOptions(method: .clipboardOnly, insertion: .replaceField, restoreClipboard: false)
        await apply(saved)
        let reopened = try WindowsAppController(directory: directory, effects: SyntheticEffects())
        let reopenedOptions = await reopened.textOutputOptions()
        let reopenedSettings = try await reopened.encodedSettings()
        await reopened.close()
        let current = try await controller.encodedSettings()
        try require(reopenedOptions == saved && reopenedSettings == current, "reopening changed the saved settings")
    }

    /// Imports and History retries have no recording hotkey, so they never
    /// output automatically, even with Copy to the clipboard saved.
    private func checkImportAndRetryNeverOutput() async throws {
        await apply(WindowsTextOutputOptions(method: .clipboardOnly))
        let source = directory.appendingPathComponent("Imported.wav")
        try SyntheticEffects.wave().write(to: source)
        let arrivals = effects.transcription.arrivals
        effects.delivery.close()
        await controller.importAudio(path: source.path, modelIndex: batchIndex)
        try await expectNoOutput(SyntheticEffects.batchText, "import")
        guard let imported = await controller.selfTestState().record else {
            throw selfTestFailure("the import saved no record")
        }
        await controller.retryHistory(imported.uuidString)
        try await expectNoOutput(SyntheticEffects.batchText, "History retry")
        try require(effects.transcription.arrivals == arrivals + 2, "import and retry did not both transcribe")
    }

    /// Closing cancels a pending copy before it can write, waits for it, and
    /// the native job then refuses any late copy.
    private func checkClosingCancelsPendingOutput() async throws {
        await apply(WindowsTextOutputOptions(method: .clipboardOnly))
        try await start(batchIndex, "closing")
        await stop(batchIndex).value
        try await eventually("held output") { self.effects.heldOutputs == 1 }
        let closed = SelfTestSwitch()
        let controller = controller
        Task {
            await controller.close()
            closed.open()
        }
        try await eventually("closing to drain the pending output") { closed.isOpen }
        try require(effects.lastOutput?.delivered == false, "closing let a pending output finish")
        guard let job = effects.lastClipboard else { throw selfTestFailure("closing had no clipboard job") }
        // An empty request never reaches the clipboard, whatever the job state.
        guard case .failure(let error as WindowsTextOutputError) = Result(catching: { try job.copy("") }),
              error.message.contains("cancelled") else {
            throw selfTestFailure("closing did not cancel the native clipboard job")
        }
    }

    /// The native dialog's own Apply path: callback, settings queue, save and
    /// the native refresh from what was saved.
    private func apply(_ options: WindowsTextOutputOptions) async {
        let choice = options.nativeChoice
        textOutputEvent(choice.method, choice.insertion, choice.restoreClipboard, context)
        await holder.finishSettings()
    }

    private func expectSaved(_ options: WindowsTextOutputOptions, _ scenario: String) async throws {
        var method: Int32 = -1, insertion: Int32 = -1, restore: Int32 = -1
        let native = jsti_window_text_output(&method, &insertion, &restore) == 0
            ? WindowsTextOutputNativeChoice(method: method, insertion: insertion, restoreClipboard: restore) : nil
        let saved = await controller.textOutputOptions()
        try require(saved == options && native == options.nativeChoice, "\(scenario) was not saved and shown")
    }

    /// Record in this window: the Record event path without a captured field.
    private func toggle(_ index: Int) -> Task<Void, Never> {
        toggleRecording(holder, target: nil, modelIndex: index, deviceID: "")
    }

    private func start(_ index: Int, _ scenario: String) async throws {
        await toggle(index).value
        let recording = await controller.selfTestState().recording
        try require(recording, "\(scenario) recording did not start")
    }

    /// Stops with automatic output held at its gate, so an output that started
    /// stays observable until it is released.
    private func stop(_ index: Int) -> Task<Void, Never> {
        effects.delivery.close()
        return toggle(index)
    }

    private func expectNoOutput(_ transcript: String, _ scenario: String) async throws {
        let state = await controller.selfTestState()
        try require(state.transcript == transcript && !state.output, "\(scenario) output automatically")
    }

    private func expectCopy(_ transcript: String, _ scenario: String) async throws {
        let state = await controller.selfTestState()
        try require(state.transcript == transcript && state.output, "\(scenario) did not start a copy")
        let completed = effects.completedOutputs
        effects.delivery.open()
        try await eventually("\(scenario) output") { self.effects.completedOutputs > completed }
        let output = effects.lastOutput
        try require(
            output == SelfTestOutput(clipboard: true, text: transcript, delivered: true), "\(scenario) did not copy"
        )
        try await eventually("\(scenario) output slot") { await !self.controller.selfTestState().output }
    }
}

private struct SelfTestState {
    let recording: Bool
    let output: Bool
    let record: UUID?
    let transcript: String?
}

extension WindowsAppController {
    fileprivate func selfTestState() -> SelfTestState {
        SelfTestState(
            recording: recording != nil, output: outputSlot.task != nil, record: selectedHistoryID,
            transcript: selectedHistoryID.flatMap { history[$0]?.displayText }
        )
    }

    /// Every setting, with sorted keys so equal settings encode identically.
    fileprivate func encodedSettings() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(settings)
    }
}

private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw selfTestFailure(message()) }
}

private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw selfTestFailure("timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
