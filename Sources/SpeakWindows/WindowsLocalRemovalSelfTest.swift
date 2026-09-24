import Foundation
import SpeakCore
import SpeakDesktop
import CWindowsSupport

/// Local model removal with the real controller and synthetic effects: no
/// microphone, credential, network, download or speech runtime is used. A
/// transcription holds the model its record uses, not the app's selected one;
/// removing the selected model returns while its teardown is still held, and
/// the model cannot be used until the teardown ends; once the transcription
/// finishes, its model can be removed too. An import holds its model from its
/// readiness check, before its record is saved, until its transcription ends.
enum WindowsLocalRemovalSelfTest {
    static func run() async throws {
        let models = DesktopLocalTranscription.models(host: .windows)
        guard models.count >= 2,
              let smallest = models.min(by: { $0.artifact.byteCount < $1.artifact.byteCount }) else {
            throw removalFailure("the catalogue has fewer than two on-device models")
        }
        try await withController { controller, effects, root in
            try await check(controller, effects: effects, used: models[1], selected: models[0], root: root)
        }
        print("Local model removal ownership self-test passed.")
        try await withController { controller, effects, root in
            try await checkImport(controller, effects: effects, model: smallest, root: root)
        }
    }

    /// A controller with synthetic effects in a fresh folder, closed after
    /// `body`. A failure first releases every held effect so closing can end.
    private static func withController(
        _ body: (WindowsAppController, SyntheticEffects, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsti-local-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = SyntheticEffects()
        let controller = try WindowsAppController(directory: root, effects: effects)
        do {
            try await body(controller, effects, root)
        } catch {
            effects.releaseAll()
            await controller.close()
            throw error
        }
        await controller.close()
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

    /// The selected model is held from the import's readiness check, so it is
    /// already in use when the new record is first saved, before transcription
    /// holds it. A failed import lets it go; a cancelled one keeps its audio.
    /// A local import needs the runtime beside the app, though nothing here
    /// loads it; without the runtime this check says it skipped.
    private static func checkImport(
        _ controller: WindowsAppController, effects: SyntheticEffects, model: WindowsModelSpec, root: URL
    ) async throws {
        guard await controller.localRuntimeBundled else {
            print("Local model import ownership self-test skipped: no on-device runtime beside this build.")
            return
        }
        guard let slot = WindowsModels.all.firstIndex(where: { $0.id == model.catalogueID }) else {
            throw removalFailure("\(model.catalogueID) has no picker slot")
        }
        let identifier = model.catalogueID
        try await installSynthetically(model, root: root)
        let readiness = await controller.localReadiness(identifier)
        try require(readiness == nil, "the synthetic model was not ready to import: \(readiness ?? "")")
        await controller.markReadyForSelfTest()
        let saves = SaveObservations()
        await controller.installCloudSync(WindowsCloudSyncHooks { [weak controller] in
            // History saves run on the controller, so its ledger is read in place.
            guard let controller else { return }
            saves.append(controller.assumeIsolated { $0.localModels.ownership.isInUse(identifier) })
        })
        await controller.importAudio(path: root.appendingPathComponent("missing.wav").path, modelIndex: slot)
        let afterFailure = await controller.localModelOwnership
        try require(saves.first == nil && !afterFailure.isInUse(identifier), "a failed import kept its model")

        let audio = root.appendingPathComponent("Imported.wav")
        try SyntheticEffects.wave().write(to: audio)
        let position = try index(of: model)
        effects.transcription.close()
        let arrivals = effects.transcription.arrivals
        let importing = Task { await controller.importAudio(path: audio.path, modelIndex: slot) }
        try await waitUntil("the import's held transcription") { effects.transcription.arrivals > arrivals }
        try require(saves.first == true, "an import let its model go before saving its record")
        await controller.localModelAction(Int32(JSTI_LOCAL_MODEL_REMOVE.rawValue), index: position)
        let whileImporting = await controller.localModelOwnership
        try require(
            whileImporting.isInUse(identifier) && !whileImporting.isRemoving(identifier),
            "an importing model was removed"
        )
        await controller.cancelTranscription()
        effects.transcription.open()
        await importing.value
        try await checkCancelledImport(controller, model: model, root: root)
    }

    /// After a cancelled import: the model is free and removable, and the
    /// imported audio is still in History with a cancelled record.
    private static func checkCancelledImport(
        _ controller: WindowsAppController, model: WindowsModelSpec, root: URL
    ) async throws {
        let identifier = model.catalogueID
        let afterImport = await controller.localModelOwnership
        try require(!afterImport.isInUse(identifier), "a cancelled import kept its model")
        guard let imported = await controller.historyForSelfTest.first(where: { $0.modelIdentifier == identifier }),
              imported.result == nil, imported.failure?.contains("cancelled") == true else {
            throw removalFailure("a cancelled import was not saved as cancelled")
        }
        let kept = root.appendingPathComponent("History").appendingPathComponent(imported.audioFilename)
        try require(FileManager.default.fileExists(atPath: kept.path), "a cancelled import lost its audio")
        let removal = try await removeWithHeldTeardown(model, from: controller)
        try require(removal.removing, "an imported model stayed in use after its transcription")
        print("Local model import ownership self-test passed.")
    }

    /// Installs `model` through the real installer into the controller's
    /// folder from zero bytes, which a stand-in digest reports as the pinned
    /// file, so the model is ready without network or weights.
    private static func installSynthetically(_ model: WindowsModelSpec, root: URL) async throws {
        let digest = model.artifact.sha256
        let installer = LocalModelInstaller(
            root: root.appendingPathComponent(WindowsAppController.localModelsFolder, isDirectory: true),
            digests: LocalModelDigestProvider(name: "Self-test pinned digest") { PinnedDigest(digest) },
            transport: ZeroBodyTransport()
        )
        try await installer.install(.init(model))
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

/// Stands in for CNG: reports the pinned digest for whatever it reads.
private final class PinnedDigest: LocalModelSHA256Hasher {
    private let digest: String

    init(_ digest: String) { self.digest = digest }

    func update(_ bytes: UnsafeRawBufferPointer) throws {}

    func finish() throws -> String { digest }
}

/// Serves the requested number of zero bytes.
private struct ZeroBodyTransport: LocalModelDownloadTransport {
    func download(
        _ request: LocalModelDownloadRequest, start: @escaping @Sendable (LocalModelDownloadStart) throws -> Void,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        try start(.fromBeginning)
        let chunk = Data(count: 4 << 20)
        var remaining = request.expectedByteCount
        while remaining > 0 {
            let count = Int(min(remaining, Int64(chunk.count)))
            try sink(chunk.prefix(count))
            remaining -= Int64(count)
        }
    }
}

/// Whether the model was in use at each History save, in order.
private final class SaveObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    var first: Bool? { lock.withLock { values.first } }

    func append(_ value: Bool) { lock.withLock { values.append(value) } }
}

extension WindowsAppController {
    fileprivate var localModelOwnership: LocalModelOwnership { localModels.ownership }
    fileprivate var localModelTeardown: LocalModelTeardown { localModels.teardown }
    fileprivate var selectedModelForSelfTest: String { settings.model }
    fileprivate var historyForSelfTest: [DesktopRecordingStore.Record] { Array(history.values) }
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
