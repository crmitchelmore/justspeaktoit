import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

let linuxApplicationID = "com.justspeaktoit.JustSpeakToIt"

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}

/// Runs async work on the cooperative pool and waits for it. The main thread
/// belongs to GTK, and nothing here needs the main actor.
final class BlockingResult<Value>: @unchecked Sendable { var result: Result<Value, Error>? }

func blocking<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) throws -> Value {
    let box = BlockingResult<Value>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

/// Deterministic checks that need no display, microphone, keyring or network.
func runSelfTest() throws {
    try LinuxNative.call { jsti_native_self_test($0, $1) }
    guard !DesktopTranscription.batchModels.isEmpty else {
        throw DesktopHostError(message: "No canonical desktop models available.")
    }
    guard DesktopHostModels.live.isEmpty == !LinuxLiveTransport.qualified else {
        throw DesktopHostError(message: "Live models are offered without a qualified transport.")
    }
    print("Native Linux adapter and canonical model self-test passed.")
}

/// Configures the window from saved settings, runs GTK on this (main) thread
/// until the window closes, then drains every queue and closes the controller.
func runWindow(controller: LinuxAppController, holder: LinuxEventContext) throws {
    let selected = try blocking { () -> Int in
        let microphone = await controller.selectedMicrophone()
        let warning = LinuxWindow.configureMicrophones(selected: microphone, synthetic: holder.smokeTest)
        await controller.setMicrophoneWarning(warning)
        try await controller.configureModelCatalog()
        holder.applyShortcutStyle(await controller.hotKeySettings())
        LinuxWindow.postProcessing(await controller.postProcessingOptions())
        return await controller.selectedIndex()
    }
    let strings = LinuxWindow.Strings()
    let rows = LinuxWindow.modelRows(strings)
    let context = Unmanaged.passUnretained(holder).toOpaque()
    var arguments = CommandLine.arguments.map { strdup($0) }
    defer { arguments.forEach { free($0) } }
    var windowFailure: Error?
    do {
        try withExtendedLifetime(strings) {
            try rows.withUnsafeBufferPointer { rows in
                try LinuxNative.call { error, capacity in
                    jsti_window_run(
                        linuxApplicationID, Int32(arguments.count), &arguments, rows.baseAddress, rows.count,
                        Int32(selected), linuxWindowEvent, context,
                        holder.smokeTest ? Int32(JSTI_WINDOW_SMOKE_TEST) : 0, error, capacity
                    )
                }
            }
        }
    } catch { windowFailure = error }
    try blocking {
        holder.shortcuts.stop()
        if !holder.smokeTest { holder.microphones.stop() }
        await holder.finishSettings()
        await holder.drainShortcuts()
        await controller.close()
        LinuxPortal.stopRemoteDesktop()
    }
    withExtendedLifetime(holder) {}
    if let windowFailure { throw windowFailure }
    if let smokeFailure = holder.smokeTestFailure { throw smokeFailure }
}

let arguments = CommandLine.arguments
DesktopHostModels.configure(streamingQualified: LinuxLiveTransport.qualified)
if arguments.contains("--version") {
    print("JustSpeakToIt for Linux (developer preview)")
    exit(0)
}
if arguments.contains("--self-test") {
    do { try runSelfTest() } catch { fail(error) }
    exit(0)
}

let integrationCheck = arguments.firstIndex(of: "--integration-test").flatMap {
    arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
}
switch integrationCheck {
case "keyring", "capture", "portal", "x11-hotkey":
    do {
        switch integrationCheck {
        case "keyring": try LinuxIntegrationChecks.keyring()
        case "capture": try LinuxIntegrationChecks.capture()
        case "x11-hotkey": try LinuxIntegrationChecks.x11Hotkey()
        default: try LinuxIntegrationChecks.portal()
        }
    } catch { fail(error) }
    exit(0)
case nil, "x11": break
default: fail(DesktopHostError(message: "Unknown integration check \(integrationCheck ?? "")."))
}

// The X11 check runs inside a throwaway window like the smoke test.
let smokeTest = arguments.contains("--ui-smoke-test") || integrationCheck == "x11"
let session = LinuxDesktopSession()
let directory = smokeTest
    ? FileManager.default.temporaryDirectory.appendingPathComponent("jsti-smoke-\(UUID().uuidString)")
    : LinuxFiles.dataDirectory()
// The remote-input portal is probed once; smoke tests never touch the desktop.
let remoteDesktop = !smokeTest && session.displayServer == .wayland
    && LinuxPortal.version(of: LinuxPortal.remoteDesktop) != nil
LinuxHostPlatform.configure(session: session, remoteDesktopAvailable: remoteDesktop)

do {
    try LinuxFiles.preparePrivateDirectory(directory)
    let controller = try LinuxAppController(directory: directory, effects: LinuxNativeEffects())
    let holder = LinuxEventContext(controller: controller, smokeTest: smokeTest)
    if integrationCheck == "x11" { holder.windowCheck = { try LinuxIntegrationChecks.x11() } }
    defer { if smokeTest { try? FileManager.default.removeItem(at: directory) } }
    try runWindow(controller: controller, holder: holder)
    if smokeTest && integrationCheck == nil { print("Native window creation and shutdown passed.") }
} catch {
    fail(error)
}
