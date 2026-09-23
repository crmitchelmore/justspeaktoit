import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

/// Local model removal with the real controller and synthetic effects: no
/// microphone, credential, network, download or speech runtime is used. A
/// transcription holds the model its record uses, not the app's selected one;
/// removing the selected model returns while its teardown is still held, and
/// the model cannot be used until the teardown ends; once the transcription
/// finishes, its model can be removed too.
enum WindowsLocalRemovalSelfTest {
    static func run() async throws {
        let models = DesktopLocalTranscription.models(host: .windows)
        guard models.count >= 2 else { throw removalFailure("the catalogue has fewer than two on-device models") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsti-local-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = SyntheticEffects()
        let controller = try WindowsAppController(directory: root, effects: effects)
        do {
            try await check(controller, effects: effects, used: models[1], selected: models[0], root: root)
        } catch {
            effects.releaseAll()
            await controller.close()
            throw error
        }
        await controller.close()
        print("Local model removal ownership self-test passed.")
    }

    private static func check(
        _ controller: WindowsAppController, effects: SyntheticEffects, used: WindowsModelSpec,
        selected: WindowsModelSpec, root: URL
    ) async throws {
        guard let slot = WindowsModels.all.firstIndex(where: { $0.id == selected.catalogueID }) else {
            throw removalFailure("\(selected.catalogueID) has no picker slot")
        }
        await controller.selectModel(slot)
        let selectedModel = await controller.selectedModelForSelfTest
        try require(selectedModel == selected.catalogueID, "the app did not select \(selected.catalogueID)")
        let id = UUID()
        let filename = id.uuidString + ".wav"
        try SyntheticEffects.wave().write(to: root.appendingPathComponent("History").appendingPathComponent(filename))
        let record = DesktopRecordingStore.Record(id: id, audioFilename: filename, modelIdentifier: used.catalogueID)
        try await controller.saveRecord(record)

        let usedIndex = try index(of: used)
        effects.transcription.close()
        let arrivals = effects.transcription.arrivals
        let transcribing = Task { await controller.transcribe(record, duration: 0, output: nil) }
        try await waitUntil("the held transcription") { effects.transcription.arrivals > arrivals }
        await controller.localModelAction(Int32(JSTI_LOCAL_MODEL_REMOVE.rawValue), index: usedIndex)
        let whileTranscribing = await controller.localModelOwnership
        try require(
            whileTranscribing.isInUse(used.catalogueID) && !whileTranscribing.isRemoving(used.catalogueID),
            "a transcription's model was removed because another model was selected"
        )
        let selectedRemoval = try await removeWithHeldTeardown(selected, from: controller)
        try require(selectedRemoval.removing, "removing an unused model waited for its teardown")
        try require(
            selectedRemoval.readiness == "\(selected.displayName) is being removed from this PC.",
            "a model being removed was ready to use"
        )

        effects.transcription.open()
        await transcribing.value
        let afterTranscription = await controller.localModelOwnership
        try require(!afterTranscription.isInUse(used.catalogueID), "a finished transcription kept its model")
        let usedRemoval = try await removeWithHeldTeardown(used, from: controller)
        try require(usedRemoval.removing, "a model stayed in use after its transcription")
    }

    /// Asks the controller to remove `model` while its teardown queue is held,
    /// and returns what the controller reported meanwhile once it has finished.
    private static func removeWithHeldTeardown(
        _ model: WindowsModelSpec, from controller: WindowsAppController
    ) async throws -> (removing: Bool, readiness: String?) {
        let position = try index(of: model)
        let teardown = await controller.localModelTeardown
        let hold = try await TeardownHold.begin(on: teardown)
        defer { hold.release() }
        await controller.localModelAction(Int32(JSTI_LOCAL_MODEL_REMOVE.rawValue), index: position)
        let removing = await controller.localModelOwnership.isRemoving(model.catalogueID)
        let readiness = await controller.localReadiness(model.catalogueID)
        hold.release()
        try await waitUntil("\(model.catalogueID) to be removed") {
            await !controller.localModelOwnership.isRemoving(model.catalogueID)
        }
        return (removing, readiness)
    }

    private static func index(of model: WindowsModelSpec) throws -> Int {
        guard let index = DesktopLocalTranscription.models(host: .windows).firstIndex(of: model) else {
            throw removalFailure("\(model.catalogueID) is not an on-device model")
        }
        return index
    }
}

/// Occupies the teardown queue, as a slow deletion or a runtime that is still
/// recognising would, until released. Releasing twice is harmless.
private final class TeardownHold: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let entered = SelfTestSwitch()

    static func begin(on teardown: LocalModelTeardown) async throws -> TeardownHold {
        let hold = TeardownHold()
        Task {
            _ = await teardown.remove({
                hold.entered.open()
                _ = hold.gate.wait(timeout: .now() + 10)
            }, release: {})
        }
        try await waitUntil("the held teardown") { hold.entered.isOpen }
        return hold
    }

    func release() { gate.signal() }
}

extension WindowsAppController {
    fileprivate var localModelOwnership: LocalModelOwnership { localModels.ownership }
    fileprivate var localModelTeardown: LocalModelTeardown { localModels.teardown }
    fileprivate var selectedModelForSelfTest: String { settings.model }
}

private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw removalFailure(message()) }
}

/// Yields rather than sleeps; the bound only turns a hang into a failure.
private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw removalFailure("timed out waiting for \(what)") }
        await Task.yield()
    }
}

private func removalFailure(_ message: String) -> WindowsNativeError {
    WindowsNativeError(message: "Local model removal self-test: \(message).")
}
