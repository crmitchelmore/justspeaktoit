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
    try LinuxActionShortcutRun.checkProjectionForSelfTest()
    guard !DesktopTranscription.batchModels.isEmpty else {
        throw DesktopHostError(message: "No canonical desktop models available.")
    }
    guard DesktopHostModels.live.isEmpty == !LinuxLiveTransport.qualified else {
        throw DesktopHostError(message: "Live models are offered without a qualified transport.")
    }
    print("Native Linux adapter and canonical model self-test passed.")
    try blocking {
        for profile in RecordingFeedbackProfile.allCases {
            guard try await LinuxRecordingFeedbackLoader.checkAssets(profile: profile) == 2 else {
                throw DesktopHostError(message: "Recording sound asset self-test did not decode both cues.")
            }
        }
    }
    print("All eight bundled Linux recording sounds decoded with the production decoder and bounds.")
    try blocking { try await LinuxShortcutGestures.checkTimingForSelfTest() }
    print("Native Linux shortcut timing self-test passed.")
    try blocking { try await LinuxLocalSelfTest.run() }
}

/// Configures the window from saved settings, runs GTK on this (main) thread
/// until the window closes, then drains every queue and closes the controller.
func runWindow(controller: LinuxAppController, holder: LinuxEventContext) throws {
    try LinuxWindow.configureAbout()
    try LinuxWindow.configureTroubleshooting(holder)
    defer { jsti_troubleshooting_clear() }
    try LinuxWindow.configureAPIKeys(holder)
    defer { jsti_api_keys_clear() }
    try LinuxWindow.configurePermissions(holder)
    defer { jsti_permissions_clear() }
    try configureApplicationIcon()
    let providerCallbacks = try LinuxWindow.beginVoiceProviderCallbacks(holder)
    defer { LinuxWindow.endVoiceProviderCallbacks(providerCallbacks) }
    let selected = try blocking { () -> Int in
        let microphone = await controller.selectedMicrophone()
        let warning = LinuxWindow.configureMicrophones(selected: microphone, synthetic: holder.smokeTest)
        await controller.setMicrophoneWarning(warning)
        try await controller.configureModelCatalog()
        holder.applyShortcutStyle(await controller.hotKeySettings())
        try await LinuxWindow.configureConfiguration(holder)
        LinuxWindow.postProcessing(await controller.postProcessingOptions())
        _ = jsti_window_set_azure_resource(await controller.azureResourceEndpoint())
        LinuxWindow.voiceOutput(await controller.voiceOutputSettings())
        LinuxWindow.voiceSources(context: Unmanaged.passUnretained(holder).toOpaque())
        _ = jsti_window_set_appearance(Int32(await controller.appearance().rawValue))
        await controller.configureLocalModels()
        await controller.configureLocalCleanup(presenter: Unmanaged.passUnretained(holder).toOpaque())
        try LinuxWindow.configureModelPreferences(await controller.preferredModelIDs())
        return await controller.selectedIndex()
    }
    LinuxCloudSync.configure(holder)
    let context = Unmanaged.passUnretained(holder).toOpaque()
    let windowFailure = runGTKEventLoop(selected: selected, context: context, holder: holder)
    LinuxWindow.endVoiceProviderCallbacks(providerCallbacks)
    try shutDownWindow(controller: controller, holder: holder)
    withExtendedLifetime(holder) {}
    if let windowFailure { throw windowFailure }
    if let smokeFailure = holder.smokeTestFailure { throw smokeFailure }
}

/// Fences callbacks, drains settings and closes the controller after the window closes.
private func shutDownWindow(controller: LinuxAppController, holder: LinuxEventContext) throws {
    try blocking {
        holder.globalActionShortcuts.stop()
        holder.shortcuts.stop()
        holder.historyPaste.stop()
        LinuxSelectedTextTarget.stopSessionAccess()
        if !holder.smokeTest { holder.microphones.stop() }
        await holder.finishSettings()
        await controller.stopProviderCredentialEdits()
        holder.apiKeys.stop()
        _ = await holder.automation.applyOffThread(enabled: false)
        await LinuxCloudSync.shutDown(holder)
        // Closing first cancels a shortcut's transcription instead of waiting
        // on its provider; queued shortcuts then find the controller closed.
        let report = await controller.close()
        await DesktopHostShutdown.wait(within: report.isComplete ? DesktopHostShutdown.grace : .zero) {
            await holder.drainShortcuts()
            await holder.apiKeys.drain()
        }
        LinuxPortal.stopRemoteDesktop()
    }
}

/// Runs the GTK event loop until the window closes, returning any error
/// raised while marshalling arguments or running `jsti_window_run` instead
/// of throwing, so the caller can still perform its own cleanup first.
private func runGTKEventLoop(selected: Int, context: UnsafeMutableRawPointer, holder: LinuxEventContext) -> Error? {
    let strings = LinuxWindow.Strings()
    let rows = LinuxWindow.modelRows(strings)
    var arguments = CommandLine.arguments.map { strdup($0) }
    defer { arguments.forEach { free($0) } }
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
        return nil
    } catch {
        return error
    }
}

func configureApplicationIcon() throws {
    guard let theme = Bundle.module.url(forResource: "hicolor", withExtension: nil) else {
        throw DesktopHostError(message: "The bundled application icon theme is missing.")
    }
    try LinuxNative.call { jsti_app_icon_configure(theme.deletingLastPathComponent().path, $0, $1) }
}

func prepareDesktopAction(_ arguments: [String], forward: Bool) throws {
    var nativeArguments = arguments.map { strdup($0) }
    defer { nativeArguments.forEach { free($0) } }
    guard nativeArguments.allSatisfy({ $0 != nil }) else {
        throw DesktopHostError(message: "Could not allocate desktop action command arguments.")
    }
    nativeArguments.append(nil)
    try LinuxNative.call {
        jsti_window_validate_action_command(Int32(arguments.count), &nativeArguments, $0, $1)
    }
    guard forward else { return }
    try LinuxNative.call {
        jsti_window_forward_action(
            linuxApplicationID, Int32(arguments.count), &nativeArguments, $0, $1
        )
    }
}

let arguments = CommandLine.arguments
let actionArguments = LinuxActionShortcutRun.forwardedCommandArguments
let forwardsAction = arguments.contains(where: { actionArguments.contains($0) })
if forwardsAction || arguments.contains(JSTI_TOGGLE_ARGUMENT) {
    do { try prepareDesktopAction(arguments, forward: forwardsAction) } catch { fail(error) }
    if forwardsAction { exit(0) }
}
DesktopHostModels.configure(
    streamingQualified: LinuxLiveTransport.qualified, local: DesktopLocalTranscription.options(host: .linux),
    localLive: DesktopLocalStreaming.options(host: .linux)
)
if arguments.contains("--version") {
    print("JustSpeakToIt for Linux (developer preview)")
    exit(0)
}
if arguments.contains("--self-test") {
    do { try runSelfTest() } catch { fail(error) }
    exit(0)
}
if arguments.contains("--recording-feedback-self-test") {
    do {
        try blocking {
            for profile in RecordingFeedbackProfile.allCases {
                let latencies = try await LinuxRecordingFeedbackLoader.checkNativeOutput(profile: profile)
                print("\(profile.rawValue) prepared recording sound queue latencies (seconds): \(latencies)")
            }
        }
    } catch { fail(error) }
    exit(0)
}
if arguments.contains("--local-transcription-self-test") {
    do { try blocking { try await LinuxLocalSelfTest.transcribe(arguments: arguments) } } catch { fail(error) }
    exit(0)
}

let integrationCheck = arguments.firstIndex(of: "--integration-test").flatMap {
    arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
}
switch integrationCheck {
case "atspi-selection":
    do { try LinuxSelectionIntegrationCheck.run() } catch { fail(error) }
    exit(0)
case "keyring", "capture", "portal", "x11-hotkey", "x11-hotkey-locks":
    do {
        switch integrationCheck {
        case "keyring": try LinuxIntegrationChecks.keyring()
        case "capture": try LinuxIntegrationChecks.capture()
        case "x11-hotkey": try LinuxIntegrationChecks.x11Hotkey()
        case "x11-hotkey-locks": try LinuxIntegrationChecks.x11Hotkey(lockStates: true)
        default: try LinuxIntegrationChecks.portal()
        }
    } catch { fail(error) }
    exit(0)
case nil, "x11": break
default: fail(DesktopHostError(message: "Unknown integration check \(integrationCheck ?? "")."))
}

// Saves a picture of every page, with sample History, for visual review.
let screenshotDirectory = arguments.firstIndex(of: "--ui-screenshots").flatMap {
    arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
}
// The X11 check and the screenshot tour run inside a throwaway window like the smoke test.
let smokeTest = arguments.contains("--ui-smoke-test") || integrationCheck == "x11" || screenshotDirectory != nil
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
    if screenshotDirectory != nil {
        try blocking { try await DesktopHostSampleHistory.seed(directory: directory) }
    }
    let needsSetup = !smokeTest && LinuxOnboarding.needsAutomaticSetup(in: directory)
    let controller = try LinuxAppController(directory: directory, effects: LinuxNativeEffects())
    let holder = LinuxEventContext(controller: controller, smokeTest: smokeTest)
    holder.needsSetupAtLaunch = needsSetup
    try LinuxOnboarding.configure(holder)
    defer { jsti_setup_clear() }
    holder.screenshotDirectory = screenshotDirectory
    if integrationCheck == "x11" { holder.windowCheck = { try LinuxIntegrationChecks.x11() } }
    defer { if smokeTest { try? FileManager.default.removeItem(at: directory) } }
    try runWindow(controller: controller, holder: holder)
    if let screenshotDirectory {
        print("Saved the window's pages to \(screenshotDirectory).")
    } else if smokeTest && integrationCheck == nil {
        print("Native window creation and shutdown passed.")
    }
} catch {
    fail(error)
}
