import Foundation
import CWindowsSupport
import SpeakDesktop
import SpeakWindowsPlatform

final class WindowsEventContext {
    let controller: WindowsAppController
    let smokeTest: Bool
    var smokeTestFailure: Error?
    let search: WindowsSearchCoalescer
    private var settingsTask: Task<Void, Never>?
    lazy var profiles = WindowsProfilesCoordinator { [weak self] profiles in
        guard let self else { return }
        self.enqueueSettings { await self.controller.saveProfiles(profiles) }
    }

    init(controller: WindowsAppController, smokeTest: Bool) {
        self.controller = controller
        self.smokeTest = smokeTest
        self.search = WindowsSearchCoalescer { query in await controller.searchHistory(query) }
    }

    // Called only by the native UI thread. Persist settings in UI event order,
    // and let shutdown drain these short operations before closing the actor.
    func enqueueSettings(_ action: @escaping @Sendable () async -> Void) {
        let previous = settingsTask
        settingsTask = Task {
            await previous?.value
            await action()
        }
    }

    var currentSettingsTask: Task<Void, Never>? { settingsTask }

    func finishSettings() async { await settingsTask?.value }
}

/// Coalesces native search keystrokes. The UI thread only records the newest
/// query and one task drains it, so a typing burst never queues an actor call
/// per keystroke and the latest query always wins.
final class WindowsSearchCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: String?
    private var draining = false
    private let perform: @Sendable (String) async -> Void

    init(perform: @escaping @Sendable (String) async -> Void) { self.perform = perform }

    func submit(_ query: String) {
        lock.lock()
        pending = query
        let alreadyDraining = draining
        draining = true
        lock.unlock()
        guard !alreadyDraining else { return }
        Task { [self] in
            while let query = self.next() { await self.perform(query) }
        }
    }

    private func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let query = pending else { draining = false; return nil }
        pending = nil
        return query
    }
}

func windowEvent(_ event: Int32, _ text: UnsafePointer<CChar>?, _ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let controller = holder.controller
    let value = text.map(String.init(cString:)) ?? ""
    switch event {
    case 1:
        // Capture synchronously before an actor hop or another app gains focus.
        // No external field focused is not an error here: the transcript is
        // still saved and offered for Copy.
        let captured = try? WindowsInsertionTarget.capture()
        let pendingSettings = holder.currentSettingsTask
        Task {
            await pendingSettings?.value
            await controller.toggle(
                target: captured, modelIndex: Int(index), deviceID: value,
                targetExecutablePath: captured?.executablePath
            )
        }
    case 2:
        let pendingSettings = holder.currentSettingsTask
        Task {
            await pendingSettings?.value
            await controller.importAudio(path: value, modelIndex: Int(index))
        }
    case 3, 15, 16: transcriptEvent(event, value: value, holder: holder)
    case 4: holder.enqueueSettings { await controller.saveKey(value, modelIndex: Int(index)) }
    case 5: holder.enqueueSettings { await controller.selectModel(Int(index)) }
    case 7:
        ready(holder)
    case 8: WindowsNative.update(value)
    case 13: holder.enqueueSettings { await controller.selectMicrophone(value) }
    default: secondaryWindowEvent(event, value: value, holder: holder)
    }
}

private func openProfiles(_ holder: WindowsEventContext) {
    let editor = holder.profiles
    guard editor.begin() else { return }
    holder.enqueueSettings {
        do { try editor.show(await holder.controller.profileSnapshot()) } catch {
            editor.cancel()
            WindowsNative.update(error.localizedDescription)
        }
    }
}

// Copy and version events read the displayed version here, on the UI thread,
// so it is paired with the record ID the same event carries.
private func transcriptEvent(_ event: Int32, value: String, holder: WindowsEventContext) {
    let controller = holder.controller
    switch event {
    case 3:
        let variant = WindowsNative.displayedTranscriptVariant()
        Task { await controller.copyTranscript(identifier: value, variant: variant) }
    case 15: holder.search.submit(value)
    case 16:
        if let variant = WindowsNative.displayedTranscriptVariant() {
            Task { await controller.selectTranscriptVariant(variant, identifier: value) }
        }
    default: break
    }
}

private func ready(_ holder: WindowsEventContext) {
    guard holder.smokeTest else {
        WindowsInsertionTarget.prepare()
        Task { await holder.controller.ready() }
        return
    }
    do {
        try WindowsNative.checked { jsti_window_self_test($0, $1) }
        if let path = ProcessInfo.processInfo.environment["JSTI_UI_SNAPSHOT_PATH"] {
            try path.withCString { path in
                try WindowsNative.checked { jsti_window_save_snapshot(path, $0, $1) }
            }
        }
    } catch { holder.smokeTestFailure = error }
    jsti_window_request_close()
}

func postProcessingEvent(
    _ enabled: Int32, _ index: Int32, _ prompt: UnsafePointer<CChar>?,
    _ newKey: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let prompt = prompt.map(String.init(cString:)) ?? ""
    let key = newKey.map(String.init(cString:)) ?? ""
    holder.enqueueSettings {
        await holder.controller.savePostProcessing(
            enabled: enabled != 0, modelIndex: Int(index), prompt: prompt, key: key
        )
        let saved = await holder.controller.postProcessingOptions()
        do {
            try WindowsNative.configurePostProcessing(saved, context: Unmanaged.passUnretained(holder).toOpaque())
        } catch { WindowsNative.update(error.localizedDescription) }
    }
}

private func secondaryWindowEvent(_ event: Int32, value: String, holder: WindowsEventContext) {
    let controller = holder.controller
    switch event {
    case 17: openProfiles(holder)
    case 9: Task { await controller.selectHistory(value) }
    case 10: Task { await controller.retryHistory(value) }
    case 11:
        // The dialog runs on the UI thread. Capture the record ID and displayed
        // version before opening it so a later selection or version change
        // cannot export a different transcript.
        let variant = WindowsNative.displayedTranscriptVariant() ?? .processed
        do {
            if let path = try WindowsNative.chooseExportPath(identifier: value) {
                Task { await controller.exportHistory(value, variant: variant, path: path) }
            }
        } catch { WindowsNative.update(error.localizedDescription) }
    case 12: Task { await controller.openHistoryAudio(value) }
    case 14: Task { await controller.cancelTranscription() }
    case 20: Task { await controller.refreshModels(force: true) }
    default: break
    }
}

@main
enum SpeakWindowsMain {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--self-test") {
                try WindowsNative.checked { jsti_native_self_test($0, $1) }
                try WindowsNative.checked { jsti_text_output_self_test($0, $1) }
                try WindowsNative.checked { jsti_private_storage_self_test($0, $1) }
                try WindowsNative.stagingSelfTest()
                try WindowsNative.checked { jsti_websocket_self_test($0, $1) }
                try WindowsNative.checked { jsti_audio_conversion_self_test($0, $1) }
                guard !DesktopTranscription.batchModels.isEmpty else {
                    throw WindowsNativeError(message: "No canonical desktop models available.")
                }
                print("Native Windows adapter and canonical model self-test passed.")
                return
            }
            let smokeTest = CommandLine.arguments.contains("--ui-smoke-test")
            let directory: URL
            if smokeTest {
                directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            } else {
                guard let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"] else {
                    throw WindowsNativeError(message: "Windows did not provide the local app data directory.")
                }
                directory = URL(fileURLWithPath: local).appendingPathComponent("JustSpeakToIt")
            }
            defer { if smokeTest { try? FileManager.default.removeItem(at: directory) } }
            let controller = try await Task.detached {
                try WindowsAppController(directory: directory)
            }.value
            let holder = WindowsEventContext(controller: controller, smokeTest: smokeTest)
            try await runWindow(controller: controller, holder: holder)
            if smokeTest { print("Native window creation and shutdown passed.") }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func runWindow(controller: WindowsAppController, holder: WindowsEventContext) async throws {
        let microphone = await controller.selectedMicrophone()
        let warning = try WindowsNative.configureMicrophones(selected: microphone, smokeTest: holder.smokeTest)
        await controller.setMicrophoneWarning(warning)
        let processing = await controller.postProcessingOptions()
        try WindowsNative.configurePostProcessing(
            processing, context: Unmanaged.passUnretained(holder).toOpaque()
        )
        let preferences = await controller.preferredModelIDs()
        try WindowsModels.configureModes(batch: preferences.batch, live: preferences.live)
        try await controller.configureModelCatalog()
        let strings = WindowsModels.all.map { Array($0.displayName.utf8CString) }
        let pointers = strings.map { chars -> UnsafeMutablePointer<CChar> in
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: chars.count)
            pointer.initialize(from: chars, count: chars.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let names: [UnsafePointer<CChar>?] = pointers.map { UnsafePointer($0) }
        let selected = await controller.selectedIndex()
        var windowFailure: Error?
        do {
            try names.withUnsafeBufferPointer { buffer in
                try WindowsNative.checked { error, capacity in
                    jsti_window_run(
                        buffer.baseAddress, buffer.count, Int32(selected), windowEvent,
                        Unmanaged.passUnretained(holder).toOpaque(), error, capacity
                    )
                }
            }
        } catch { windowFailure = error }
        await holder.finishSettings()
        await controller.close()
        withExtendedLifetime(holder) {}
        if let windowFailure { throw windowFailure }
        if let smokeFailure = holder.smokeTestFailure { throw smokeFailure }
    }
}
