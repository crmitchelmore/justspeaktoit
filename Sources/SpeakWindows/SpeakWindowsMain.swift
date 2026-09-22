import Foundation
import CWindowsSupport
import SpeakDesktop

final class WindowsEventContext {
    let controller: WindowsAppController
    let smokeTest: Bool
    var smokeTestFailure: Error?
    private var settingsTask: Task<Void, Never>?

    init(controller: WindowsAppController, smokeTest: Bool) {
        self.controller = controller
        self.smokeTest = smokeTest
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

    func finishSettings() async { await settingsTask?.value }
}

func windowEvent(_ event: Int32, _ text: UnsafePointer<CChar>?, _ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let controller = holder.controller
    let value = text.map(String.init(cString:)) ?? ""
    switch event {
    case 1:
        // Capture synchronously before an actor hop or another app gains focus.
        var target = JSTITextTarget()
        var error = [CChar](repeating: 0, count: 1024)
        let captured = jsti_target_capture(&target, &error, error.count) == 0 ? target : nil
        Task { await controller.toggle(target: captured, modelIndex: Int(index)) }
    case 2: Task { await controller.importAudio(path: value, modelIndex: Int(index)) }
    case 3: Task { await controller.copyTranscript(identifier: value) }
    case 4: holder.enqueueSettings { await controller.saveKey(value, modelIndex: Int(index)) }
    case 5: holder.enqueueSettings { await controller.selectModel(Int(index)) }
    case 7:
        ready(holder)
    case 8: WindowsNative.update(value)
    default: historyEvent(event, value: value, controller: controller)
    }
}

private func ready(_ holder: WindowsEventContext) {
    guard holder.smokeTest else { Task { await holder.controller.ready() }; return }
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

private func historyEvent(_ event: Int32, value: String, controller: WindowsAppController) {
    switch event {
    case 9: Task { await controller.selectHistory(value) }
    case 10: Task { await controller.retryHistory(value) }
    case 11:
        // The dialog runs on the UI thread. Capture the record ID before opening
        // it so a later selection change cannot export a different transcript.
        do {
            if let path = try WindowsNative.chooseExportPath(identifier: value) {
                Task { await controller.exportHistory(value, path: path) }
            }
        } catch { WindowsNative.update(error.localizedDescription) }
    case 12: Task { await controller.openHistoryAudio(value) }
    default: break
    }
}

@main
enum SpeakWindowsMain {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--self-test") {
                try WindowsNative.checked { jsti_native_self_test($0, $1) }
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
            let controller = try WindowsAppController(directory: directory)
            let holder = WindowsEventContext(controller: controller, smokeTest: smokeTest)
            try await runWindow(controller: controller, holder: holder)
            if smokeTest { print("Native window creation and shutdown passed.") }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func runWindow(controller: WindowsAppController, holder: WindowsEventContext) async throws {
        let processing = await controller.postProcessingOptions()
        try WindowsNative.configurePostProcessing(
            processing, context: Unmanaged.passUnretained(holder).toOpaque()
        )
        let strings = DesktopTranscription.batchModels.map { Array($0.displayName.utf8CString) }
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
