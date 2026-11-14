import Foundation
import CWindowsSelfTest
import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

final class WindowsEventContext: DesktopNativeEventHolder {
    let controller: WindowsAppController
    let smokeTest: Bool
    private let issueReportTasks = WindowsIssueReportTasks()
    var smokeTestFailure: Error?
    var screenshotDirectory: String?
    var microphoneMonitor: WindowsMicrophoneMonitor?
    var cloudSync: WindowsCloudSync?
    let search: WindowsSearchCoalescer
    private let historyEvents: DesktopEventDispatcher<DesktopHistoryEvent>
    private let copies: DesktopTranscriptCopyDispatcher
    private let settings = DesktopSettingsQueue()
    let historyPaste = DesktopHistoryPasteAdmission()
    lazy var commandPalette = WindowsCommandPalette(history: controller.paletteHistory)
    let postProcessingPicker = DesktopPostProcessingPicker()
    lazy var hotKeys = WindowsHotKeyGestures { [controller] request in await controller.hotKey(request) }
    lazy var automation = WindowsAutomationSwitch(controller: controller)
    lazy var systemResources = WindowsSystemResources.makeMonitor()
    let hotKeyResource = WindowsHotKeyResource()
    lazy var profiles = WindowsProfilesCoordinator { [weak self] profiles in
        guard let self else { return }
        self.enqueueSettings { await self.controller.saveProfiles(profiles) }
    }
    /// The context every native window callback receives. It retains this
    /// holder until shutdown unregisters it; later callbacks then do nothing.
    private(set) var callbacks: NativeCallbackContext<WindowsEventContext>!
    var callbackContext: UnsafeMutableRawPointer { callbacks.pointer }

    init(controller: WindowsAppController, smokeTest: Bool) {
        self.controller = controller
        self.smokeTest = smokeTest
        self.search = WindowsSearchCoalescer { query in await controller.searchHistory(query) }
        self.copies = DesktopTranscriptCopyDispatcher { text, variant in
            await controller.copyTranscript(text, variant: variant)
        }
        self.historyEvents = Self.makeHistoryEvents(controller)
        callbacks = NativeCallbackContext(self)
    }

    /// Issue report work may suspend in a chooser or browser, so it never
    /// joins the settings or History queues that Close and shutdown drain.
    func submitIssueReport(ticket: UUID, _ operation: @escaping @Sendable () async -> Void) {
        issueReportTasks.submit(ticket: ticket, operation: operation)
    }

    /// Cancels one preview's work, or every preview's when `ticket` is nil.
    func cancelIssueReports(ticket: UUID? = nil) { issueReportTasks.cancel(ticket: ticket) }

    func copyTranscript(_ text: String, variant: DesktopTranscriptVariant?) {
        copies.submit(text, variant: variant)
    }

    func selectHistory(_ identifier: String) { historyEvents.submit(.selection(identifier)) }
    func selectHistoryVersion(_ variant: DesktopTranscriptVariant, identifier: String) {
        historyEvents.submit(.version(identifier, variant))
    }

    /// Play/Pause, Stop and Read aloud join the selection order: a click on a
    /// newly selected row reaches it after that selection, and Stop reaches
    /// the host after the clicks before it, never before them.
    func submitHistoryPlayback(_ event: DesktopHistoryEvent) { historyEvents.submit(event) }

    // Called only by the native UI thread. Persist settings in UI event order,
    // and let shutdown drain these short operations before closing the actor.
    func enqueueSettings(_ action: @escaping @Sendable () async -> Void) { settings.submit(action) }

    var currentSettingsTask: Task<Void, Never>? { settings.current }

    func finishSettings() async { await settings.drain() }

    func pasteLastHistory() {
        guard let request = historyPaste.begin() else {
            WindowsNative.update("History paste is already pending or the app is closing. No new target was captured.")
            return
        }
        let target = try? WindowsInsertionTarget.capture()
        let controller = controller
        enqueueSettings {
            defer { request.finish() }
            await controller.pasteLastHistoryItem(target: target, request: request)
        }
    }

    /// Called by the UI thread at the Record event. Reads text output in
    /// settings order: an Apply before Record is used, and one after it cannot
    /// reach this recording however late the recording task runs.
    func recordingTextOutput() -> Task<WindowsTextOutputOptions, Never> {
        let controller = controller
        return settings.read { await controller.textOutputOptions() }
    }

    func recordingEvent(
        modelIndex: Int, executablePath: String?
    ) -> Task<DesktopHostRecordingEvent<WindowsHostPlatform>, Never> {
        let controller = controller
        return settings.read {
            await controller.captureRecordingEvent(modelIndex: modelIndex, executablePath: executablePath)
        }
    }
}

@main
enum SpeakWindowsMain {
    static func main() async {
        // A GUI-subsystem image has no console: diagnostic flags print to the launching
        // terminal, and a Start menu launch writes to NUL rather than an invalid handle.
        let commandLine = CommandLine.arguments.dropFirst().contains(where: { $0 != "--background" })
        _ = jsti_console_prepare(commandLine ? 1 : 0)
        WindowsModels.configureForWindows()
        do {
            if try await WindowsCommandLineSelfTests.handle(CommandLine.arguments) { return }
            let screenshots = WindowsPresentation.screenshotDirectory(CommandLine.arguments)
            let smokeTest = CommandLine.arguments.contains("--ui-smoke-test") || screenshots != nil
            let directory: URL
            if smokeTest {
                directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try WindowsNative.createSyntheticDirectory(directory)
            } else {
                guard let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"] else {
                    throw WindowsNativeError(message: "Windows did not provide the local app data directory.")
                }
                directory = URL(fileURLWithPath: local).appendingPathComponent("JustSpeakToIt")
                try WindowsHostPlatform.preparePrivateDirectory(directory)
            }
            defer { if smokeTest { try? FileManager.default.removeItem(at: directory) } }
            if screenshots != nil { try await DesktopHostSampleHistory.seed(directory: directory) }
            DesktopHostOnboarding.adoptExistingInstall(directory: directory)
            let controller = try await Task.detached {
                try WindowsAppController(directory: directory)
            }.value
            let holder = WindowsEventContext(controller: controller, smokeTest: smokeTest)
            holder.screenshotDirectory = screenshots
            try await runWindow(controller: controller, holder: holder)
            if smokeTest { print("Native window creation and shutdown passed.") }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    /// Restores the shortcut fallback and canonical Read aloud voice before launch.
    private static func configureHotKey(_ holder: WindowsEventContext) async throws {
        var hotKey = await holder.controller.hotKeySettings()
        let context = holder.callbackContext
        guard WindowsNative.configureVoiceOutput(await holder.controller.voiceOutputSettings(), context: context) else {
            throw WindowsNativeError(message: "Could not configure Read aloud.")
        }
        if !WindowsNative.configureHotKey(hotKey, context: context) {
            hotKey = WindowsHotKeySettings()
            guard WindowsNative.configureHotKey(hotKey, context: context) else {
                throw WindowsNativeError(message: "Could not configure the keyboard shortcut.")
            }
        }
        holder.hotKeys.configure(style: hotKey.activation)
    }

    /// A hand-edited endpoint the dialog cannot show falls back to none rather
    /// than blocking launch; the saved setting is unchanged until the next Apply.
    private static func configureAzureResource(_ holder: WindowsEventContext) async throws {
        let context = holder.callbackContext
        guard WindowsNative.configureAzureResource(await holder.controller.azureResourceEndpoint(), context: context)
                || WindowsNative.configureAzureResource("", context: context) else {
            throw WindowsNativeError(message: "Could not configure the Azure Speech resource.")
        }
    }

    /// Restores native dialog state and services before the window opens.
    private static func configureWindow(controller: WindowsAppController, holder: WindowsEventContext) async throws {
        guard jsti_window_configure_global_escape(holder.smokeTest ? 0 : 1) == 0 else {
            throw WindowsNativeError(message: "Could not configure active-only Escape cancellation.")
        }
        let microphone = await controller.selectedMicrophone()
        let smokeTest = holder.smokeTest
        let warning = try await Task.detached {
            try WindowsNative.configureMicrophones(selected: microphone, smokeTest: smokeTest)
        }.value
        await controller.setMicrophoneWarning(warning)
        let processing = await controller.postProcessingOptions()
        try WindowsNative.configurePostProcessing(
            processing, context: holder.callbackContext
        )
        let textOutput = await controller.textOutputOptions()
        try WindowsNative.configureTextOutput(textOutput, context: holder.callbackContext)
        // Before the window registers the shortcut, so its first registration is held.
        holder.hotKeyResource.start()
        try await configureHotKey(holder)
        guard await WindowsNative.configureActionShortcuts(holder) else {
            throw WindowsNativeError(message: "Could not configure action shortcuts.")
        }
        try await WindowsNative.configureConfiguration(holder)
        try await configureAzureResource(holder)
        await configureAPIKeys(holder)
        await restoreServices(holder)
        try await configureModelPickers(controller, holder: holder)
        try await controller.configureModelCatalog()
        await WindowsPresentation.configureAppearance(controller)
        holder.configurePermissions()
        try holder.configureTroubleshooting()
        holder.configureGuide()
        await WindowsPresentation.configureShell(controller)
    }

    // Keep immediate report retirement beside the existing native-loop teardown.
    // swiftlint:disable:next function_body_length
    private static func runWindow(controller: WindowsAppController, holder: WindowsEventContext) async throws {
        defer { holder.cancelIssueReports() }
        defer { holder.hotKeyResource.stop() }
        try WindowsNative.configureAbout()
        let providerCallbacks = try WindowsNative.beginVoiceProviderCallbacks(holder)
        defer { WindowsNative.endVoiceProviderCallbacks(providerCallbacks) }
        try await configureWindow(controller: controller, holder: holder)
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
                        holder.callbackContext, error, capacity
                    )
                }
            }
        } catch { windowFailure = error }
        holder.cancelIssueReports()
        holder.systemResources.stop()
        let monitor = holder.microphoneMonitor
        await Task.detached { monitor?.stop() }.value
        holder.microphoneMonitor = nil
        WindowsNative.endVoiceProviderCallbacks(providerCallbacks)
        holder.historyPaste.stop()
        await holder.finishSettings()
        await controller.stopProviderCredentialEdits()
        // A drained Apply may have refreshed the dialog; never leave it holding
        // this context once the holder can be released.
        jsti_window_clear_text_output()
        jsti_window_clear_hotkey()
        jsti_window_clear_action_shortcuts()
        jsti_window_clear_azure_resource()
        jsti_window_clear_api_keys()
        jsti_window_clear_configuration()
        jsti_guide_clear()
        jsti_permissions_clear()
        jsti_troubleshooting_clear()
        await releaseServices(holder)
        await WindowsAutomationSwitch.shutDown(holder)
        // Closing first cancels a shortcut's transcription instead of waiting
        // on its provider; queued shortcuts then find the controller closed.
        let report = await controller.close()
        let hotKeys = holder.hotKeys
        await DesktopHostShutdown.wait(within: report.isComplete ? DesktopHostShutdown.grace : .zero) {
            await hotKeys.drain()
        }
        // Every native registration is cleared; a late callback finds nothing.
        holder.profiles.callbacks.unregister()
        holder.callbacks.unregister()
        if let windowFailure { throw windowFailure }
        if let smokeFailure = holder.smokeTestFailure { throw smokeFailure }
    }
}
