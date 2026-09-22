import Foundation
import CWindowsSupport
import SpeakDesktop

final class WindowsEventContext {
    let controller: WindowsAppController
    let smokeTest: Bool

    init(controller: WindowsAppController, smokeTest: Bool) {
        self.controller = controller
        self.smokeTest = smokeTest
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
        var target = JSTITextTarget()
        var error = [CChar](repeating: 0, count: 1024)
        let captured = jsti_target_capture(&target, &error, error.count) == 0 ? target : nil
        Task { await controller.toggle(target: captured, modelIndex: Int(index)) }
    case 2: Task { await controller.importAudio(path: value, modelIndex: Int(index)) }
    case 3: Task { await controller.copyTranscript() }
    case 4: Task { await controller.saveKey(value, modelIndex: Int(index)) }
    case 5: Task { await controller.selectModel(Int(index)) }
    case 7:
        if holder.smokeTest { jsti_window_request_close() } else { Task { await controller.ready() } }
    case 8: WindowsNative.update(value)
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
            await controller.close()
            withExtendedLifetime(holder) {}
            if let windowFailure { throw windowFailure }
            if smokeTest { print("Native window creation and shutdown passed.") }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
