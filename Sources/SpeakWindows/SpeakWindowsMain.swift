// swiftlint:disable file_length
import Foundation
import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

final class WindowsEventContext {
    let controller: WindowsAppController
    let smokeTest: Bool
    fileprivate let issueReportTasks = WindowsIssueReportTasks()
    var smokeTestFailure: Error?
    var screenshotDirectory: String?
    var microphoneMonitor: WindowsMicrophoneMonitor?
    var cloudSync: WindowsCloudSync?
    let search: WindowsSearchCoalescer
    private let historyEvents: DesktopEventDispatcher<DesktopHistoryEvent>
    private let copies: DesktopTranscriptCopyDispatcher
    private let settings = DesktopSettingsQueue()
    let historyPaste = DesktopHistoryPasteAdmission()
    let postProcessingPicker = DesktopPostProcessingPicker()
    lazy var hotKeys = WindowsHotKeyGestures { [controller] request in await controller.hotKey(request) }
    lazy var automation = WindowsAutomationSwitch(controller: controller)
    lazy var profiles = WindowsProfilesCoordinator { [weak self] profiles in
        guard let self else { return }
        self.enqueueSettings { await self.controller.saveProfiles(profiles) }
    }

    init(controller: WindowsAppController, smokeTest: Bool) {
        self.controller = controller
        self.smokeTest = smokeTest
        self.search = WindowsSearchCoalescer { query in await controller.searchHistory(query) }
        self.copies = DesktopTranscriptCopyDispatcher { text, variant in
            await controller.copyTranscript(text, variant: variant)
        }
        self.historyEvents = DesktopEventDispatcher(coalescing: DesktopHistoryEvent.coalesce) { event in
            switch event {
            case .selection(let identifier): await controller.selectHistory(identifier)
            case .version(let identifier, let variant):
                await controller.selectTranscriptVariant(variant, identifier: identifier)
            case .playPause(let identifier): await controller.playbackToggle(identifier)
            case .stop: await controller.playbackStop()
            case .readAloud(let identifier, let text): await controller.readAloud(identifier, text: text)
            case .filter(let payload): await controller.applyHistoryFilters(payload)
            case .voiceRead, .voiceExport, .voiceImport, .voiceImportCancel,
                 .voiceGenerate, .voiceGeneratedPlay, .voiceGeneratedExport:
                await controller.performVoiceEvent(event) {
                    WindowsNative.voiceTextImported($1, requestID: $0)
                }
            }
        }
    }

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
        toggleRecording(
            controller, target: captured,
            event: holder.recordingEvent(modelIndex: Int(index), executablePath: captured?.executablePath),
            modelIndex: Int(index),
            deviceID: value
        )
    case 2:
        let pendingSettings = holder.currentSettingsTask
        Task {
            await pendingSettings?.value
            await controller.importAudio(path: value, modelIndex: Int(index))
        }
    case 3, 6, 15, 16, 18, 19: transcriptEvent(event, value: value, holder: holder)
    case 4: saveKeyEvent(value, index: Int(index), holder: holder)
    case 5: holder.enqueueSettings { await controller.selectModel(Int(index)) }
    case 7:
        ready(holder)
    case 8: WindowsNative.update(value)
    case 13: holder.enqueueSettings { await controller.selectMicrophone(value) }
    default: secondaryWindowEvent(event, value: value, index: Int(index), holder: holder)
    }
}

/// Like Copy, Read aloud captures the displayed text on the UI thread, paired
/// with the record ID its event carries.
private func readAloudEvent(_ identifier: String, holder: WindowsEventContext) {
    do {
        let text = try WindowsNative.displayedTranscript()
        holder.submitHistoryPlayback(.readAloud(identifier, text: text))
    } catch { WindowsNative.update(error.localizedDescription) }
}

/// Shortcut press, release and gesture deadline on the UI thread.
private func hotKeyWindowEvent(_ event: Int32, value: String, index: Int, holder: WindowsEventContext) {
    switch event {
    case 21:
        // As at the Record event: capture the focused field before anything else can change it.
        let captured = try? WindowsInsertionTarget.capture()
        if holder.hotKeys.style != .pressToToggle, !holder.smokeTest {
            let controller = holder.controller
            Task { await controller.warmMicrophoneForShortcutPress(deviceID: value) }
        }
        let event = holder.recordingEvent(modelIndex: index, executablePath: captured?.executablePath)
        holder.hotKeys.keyDown(
            target: captured, textOutput: Task { await event.value.textOutput },
            modelIndex: index, deviceID: value, event: event
        )
    case 22: holder.hotKeys.keyUp()
    case 23: holder.hotKeys.deadlineReached()
    default: break
    }
}

// Copy and version events read the displayed version here, on the UI thread,
// so it is paired with the record ID the same event carries. Playback events
// carry the selected record ID for the same reason, in the selection order.
private func transcriptEvent(_ event: Int32, value: String, holder: WindowsEventContext) {
    switch event {
    case 3:
        let variant = WindowsNative.displayedTranscriptVariant()
        do {
            let text = try WindowsNative.displayedTranscript()
            holder.copyTranscript(text, variant: variant)
        } catch { WindowsNative.update(error.localizedDescription) }
    case 6:
        holder.issueReportTasks.cancel()
        holder.microphoneMonitor?.cancel()
    case 15: holder.search.submit(value)
    case 16:
        if let variant = WindowsNative.displayedTranscriptVariant() {
            holder.selectHistoryVersion(variant, identifier: value)
        }
    case 18: holder.submitHistoryPlayback(.playPause(value))
    case 19: holder.submitHistoryPlayback(.stop)
    default: break
    }
}

private func ready(_ holder: WindowsEventContext) {
    if WindowsPresentation.startScreenshotTour(holder) { return }
    guard holder.smokeTest else {
        WindowsInsertionTarget.prepare()
        do {
            holder.microphoneMonitor = try WindowsMicrophoneMonitor()
        } catch {
            error.localizedDescription.withCString { _ = jsti_window_refresh_microphones(nil, 0, $0) }
        }
        Task {
            await WindowsPermissions.prepareWarning(holder)
            await holder.controller.ready()
            await holder.openGuideIfNeeded()
        }
        let controller = holder.controller
        holder.enqueueSettings { await controller.refreshLoginItem() }
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

private func secondaryWindowEvent(_ event: Int32, value: String, index: Int, holder: WindowsEventContext) {
    if windowsHistoryManagementEvent(event, value: value, index: index, holder: holder) { return }
    if (70...72).contains(event) {
        return windowsVocabularyEvent(event, payload: value, kind: index, holder: holder)
    }
    if (21...23).contains(event) { return hotKeyWindowEvent(event, value: value, index: index, holder: holder) }
    if event == 24 { return readAloudEvent(value, holder: holder) }
    if event == 25 { return automationEvent(requested: value == "1", holder: holder) }
    if event == 26 { return WindowsPresentation.appearanceEvent(value, holder: holder) }
    if event == 27 {
        let controller = holder.controller
        return holder.enqueueSettings { await controller.setLaunchAtLogin(value == "1") }
    }
    if (151...155).contains(event) {
        issueReportWindowEvent(value, event: event, included: index == 1, holder: holder)
        return
    }
    otherWindowEvent(event, value: value, holder: holder)
}

// swiftlint:disable:next cyclomatic_complexity
private func otherWindowEvent(_ event: Int32, value: String, holder: WindowsEventContext) {
    let controller = holder.controller
    switch event {
    case Int32(JSTI_EVENT_HISTORY_ISSUE_REPORT.rawValue):
        holder.issueReportTasks.submit(ticket: UUID()) { await controller.beginIssueReport(value) }
    case 17: holder.openProfiles()
    case 9: holder.selectHistory(value)
    case 10: Task { await controller.retryHistory(value) }
    case 11: exportHistoryWindowEvent(value, holder: holder)
    case 12: Task { await controller.openHistoryAudio(value) }
    case 14: windowsCancelOperation(value, holder: holder)
    case Int32(JSTI_EVENT_USER_ABSENT.rawValue): Task { await controller.handsFreeUserAbsent(value) }
    case 20: Task { await controller.refreshModels(force: true) }
    case 110:
        guard let slot = Int(value) else { return }
        holder.enqueueSettings { await controller.selectQuickVoice(slot) }
    case 111:
        holder.pasteLastHistory()
    case 112:
        do {
            let target = try WindowsInsertionTarget.captureSelection()
            holder.enqueueSettings {
                await controller.readVoiceSource(.externalSelection) { try await target.selectedText() }
            }
        } catch { WindowsNative.update("Read aloud failed: \(error.localizedDescription)") }
    case 113:
        holder.enqueueSettings { await controller.readClipboardAloud() }
    case 114:
        WindowsVoiceEdit.toggle(holder)
    case Int32(JSTI_EVENT_SPEECH_PAUSE.rawValue):
        holder.enqueueSettings { await controller.pauseResumeSpeech() }
    default: break
    }
}

// These tasks may suspend in a chooser/browser. Never queue them ahead of
// Close or a replacement preview in the serialized settings/history workers.
private func issueReportWindowEvent(
    _ value: String, event: Int32, included: Bool, holder: WindowsEventContext
) {
    guard let ticket = UUID(uuidString: value) else { return }
    let controller = holder.controller
    if event == Int32(JSTI_EVENT_ISSUE_REPORT_CLOSE.rawValue) {
        holder.issueReportTasks.cancel(ticket: ticket)
        Task { await controller.cancelIssueReport(ticket) }
        return
    }
    holder.issueReportTasks.submit(ticket: ticket) {
        switch event {
        case Int32(JSTI_EVENT_ISSUE_REPORT_INCLUDE.rawValue):
            await controller.setIssueReportIncludesDiagnostics(included, ticket: ticket)
        case Int32(JSTI_EVENT_ISSUE_REPORT_COPY.rawValue): await controller.copyIssueReport(ticket)
        case Int32(JSTI_EVENT_ISSUE_REPORT_SAVE.rawValue): await controller.exportIssueReport(ticket)
        case Int32(JSTI_EVENT_ISSUE_REPORT_OPEN.rawValue): await controller.openIssueReport(ticket)
        default: break
        }
    }
}

private func exportHistoryWindowEvent(_ value: String, holder: WindowsEventContext) {
    // Snapshot before the dialog's nested loop can replace the displayed record.
    let controller = holder.controller
    let variant = WindowsNative.displayedTranscriptVariant() ?? .processed
    do {
        let text = try WindowsNative.displayedTranscript()
        if let path = try WindowsNative.chooseExportPath(identifier: value) {
            Task { await controller.exportHistory(text: text, variant: variant, path: path) }
        }
    } catch { WindowsNative.update(error.localizedDescription) }
}

@main
enum SpeakWindowsMain {
    static func main() async {
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
        let context = Unmanaged.passUnretained(holder).toOpaque()
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
        let context = Unmanaged.passUnretained(holder).toOpaque()
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
            processing, context: Unmanaged.passUnretained(holder).toOpaque()
        )
        let textOutput = await controller.textOutputOptions()
        try WindowsNative.configureTextOutput(textOutput, context: Unmanaged.passUnretained(holder).toOpaque())
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
        defer { holder.issueReportTasks.cancel() }
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
                        buffer.baseAddress, buffer.count, Int32(selected), comparisonWindowEvent,
                        Unmanaged.passUnretained(holder).toOpaque(), error, capacity
                    )
                }
            }
        } catch { windowFailure = error }
        holder.issueReportTasks.cancel()
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
        withExtendedLifetime(holder) {}
        if let windowFailure { throw windowFailure }
        if let smokeFailure = holder.smokeTestFailure { throw smokeFailure }
    }
}

// Each shared admission gets its own native handle; no callback can select a
// later preview through a process-global "current report".
final class WindowsIssueReportBridge: @unchecked Sendable {
    fileprivate let handle: OpaquePointer

    private init?() {
        guard let handle = jsti_issue_report_create() else { return nil }
        self.handle = handle
    }

    deinit { jsti_issue_report_release(handle) }

    static func actions() -> DesktopHostIssueReportActions? {
        guard let bridge = WindowsIssueReportBridge() else { return nil }
        return .init(
            present: { bridge.present($0) },
            dismiss: { _ in jsti_issue_report_retire(bridge.handle) },
            chooseDestination: { await bridge.choose($0) },
            copy: { try await bridge.copy($0) },
            open: { await bridge.open($0) }
        )
    }

    private func present(_ preview: DesktopHostIssueReportPreview) -> Bool {
        let report = preview.report
        return withIssueReportStrings([
            preview.ticket.uuidString, report.title, report.body, report.jsonString,
            report.issueURL?.absoluteString ?? "", preview.status?.message ?? ""
        ]) { values in
            jsti_issue_report_present(
                handle, values[0], values[1], values[2], values[3], values[4], values[5],
                preview.includesDiagnostics ? 1 : 0, preview.isExporting ? 1 : 0,
                preview.isOpening || preview.isCopying ? 1 : 0
            ) == 0
        }
    }

    private func copy(_ body: String) async throws {
        let pending = WindowsIssueReportPending(owner: self)
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion = WindowsIssueReportCompletion.accepted(continuation)
                pending.register(completion) { context in
                    withIssueReportStrings([pending.identifier, body]) { values in
                        jsti_issue_report_copy(handle, values[0], values[1], issueReportResult, context)
                    }
                }
            }
        } onCancel: { pending.cancel() }
        guard accepted else { throw WindowsNativeError(message: "Could not copy the draft.") }
    }

    private func choose(_ filename: String) async -> DesktopHostIssueReportDestination {
        let pending = WindowsIssueReportPending(owner: self)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion = WindowsIssueReportCompletion.destination(continuation)
                pending.register(completion) { context in
                    withIssueReportStrings([pending.identifier, filename]) { values in
                        jsti_issue_report_choose(handle, values[0], values[1], issueReportResult, context)
                    }
                }
            }
        } onCancel: { pending.cancel() }
    }

    private func open(_ url: URL) async -> Bool {
        let pending = WindowsIssueReportPending(owner: self)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion = WindowsIssueReportCompletion.accepted(continuation)
                pending.register(completion) { context in
                    withIssueReportStrings([pending.identifier, url.absoluteString]) { values in
                        jsti_issue_report_open(handle, values[0], values[1], issueReportResult, context)
                    }
                }
            }
        } onCancel: { pending.cancel() }
    }
}

// Native registration is queue-only and never invokes the callback inline.
// The brief lock closes cancel-before-registration without blocking the UI,
// an actor, OS operation or callback completion.
private final class WindowsIssueReportPending: @unchecked Sendable {
    let identifier = UUID().uuidString
    private let owner: WindowsIssueReportBridge
    private let lock = NSLock()
    private var cancelled = false
    private var registered = false

    init(owner: WindowsIssueReportBridge) { self.owner = owner }

    func register(
        _ completion: WindowsIssueReportCompletion,
        start: (UnsafeMutableRawPointer) -> Int32
    ) {
        lock.lock()
        if cancelled {
            lock.unlock()
            completion.finish(1, value: nil)
            return
        }
        let context = Unmanaged.passRetained(completion).toOpaque()
        let accepted = start(context) == 0
        registered = accepted
        lock.unlock()
        if !accepted {
            Unmanaged<WindowsIssueReportCompletion>.fromOpaque(context).release()
            completion.finish(2, value: nil)
        }
    }

    func cancel() {
        let shouldCancel = lock.withLock {
            cancelled = true
            return registered
        }
        if shouldCancel { identifier.withCString { jsti_issue_report_cancel(owner.handle, $0) } }
    }
}

private final class WindowsIssueReportCompletion: @unchecked Sendable {
    private enum Result {
        case destination(CheckedContinuation<DesktopHostIssueReportDestination, Never>)
        case accepted(CheckedContinuation<Bool, Never>)
    }
    private let result: Result
    private init(_ result: Result) { self.result = result }

    static func destination(
        _ continuation: CheckedContinuation<DesktopHostIssueReportDestination, Never>
    ) -> WindowsIssueReportCompletion { .init(.destination(continuation)) }

    static func accepted(_ continuation: CheckedContinuation<Bool, Never>) -> WindowsIssueReportCompletion {
        .init(.accepted(continuation))
    }

    func finish(_ code: Int32, value: String?) {
        switch result {
        case .destination(let continuation):
            if code == 0, let value, !value.isEmpty {
                continuation.resume(returning: .selected(URL(fileURLWithPath: value)))
            } else { continuation.resume(returning: code == 1 ? .cancelled : .failed) }
        case .accepted(let continuation): continuation.resume(returning: code == 0)
        }
    }
}

private func issueReportResult(_ code: Int32, _ value: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let completion = Unmanaged<WindowsIssueReportCompletion>.fromOpaque(context).takeRetainedValue()
    completion.finish(code, value: value.map { String(cString: $0) })
}

private func withIssueReportStrings<Value>(
    _ values: [String], _ body: ([UnsafePointer<CChar>]) -> Value
) -> Value {
    let buffers = values.map { value -> UnsafeMutablePointer<CChar> in
        let bytes = Array(value.utf8CString)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        buffer.initialize(from: bytes, count: bytes.count)
        return buffer
    }
    defer { buffers.forEach { $0.deallocate() } }
    return body(buffers.map { UnsafePointer($0) })
}

// Tracks only unfinished operations, using private per-operation identities.
// A Task cannot enter the actor before its handle is attached. Cancellation
// before attachment therefore cannot resurrect untracked chooser/export work.
final class WindowsIssueReportTasks: @unchecked Sendable {
    private final class Slot: @unchecked Sendable {
        let identifier = UUID()
        let ticket: UUID
        var task: Task<Void, Never>?
        var ready: CheckedContinuation<Bool, Never>?
        var attached = false
        var retired = false
        init(ticket: UUID) { self.ticket = ticket }
    }
    private let lock = NSLock()
    private var slots: [UUID: Slot] = [:]
    private var closed = false

    func submit(ticket: UUID, operation: @escaping @Sendable () async -> Void) {
        let slot = Slot(ticket: ticket)
        guard lock.withLock({
            guard !closed else { return false }
            slots[slot.identifier] = slot
            return true
        }) else { return }
        let task = Task { [self] in
            defer { finish(slot) }
            guard await isAttached(slot), !Task.isCancelled else { return }
            await operation()
        }
        var waiter: CheckedContinuation<Bool, Never>?
        let cancelled = lock.withLock {
            let valid = !closed && !slot.retired && slots[slot.identifier] === slot
            slot.attached = true
            if valid { slot.task = task }
            waiter = slot.ready
            slot.ready = nil
            return !valid
        }
        if cancelled { task.cancel() }
        waiter?.resume(returning: !cancelled)
    }

    private func isAttached(_ slot: Slot) async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate: Bool? = lock.withLock {
                if closed || slot.retired || slots[slot.identifier] !== slot { return false }
                if slot.attached { return true }
                slot.ready = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    private func finish(_ slot: Slot) {
        lock.withLock {
            slot.retired = true
            slot.task = nil
            if slots[slot.identifier] === slot { slots.removeValue(forKey: slot.identifier) }
        }
    }

    func cancel(ticket: UUID? = nil) {
        var tasks: [Task<Void, Never>] = []
        var waiters: [CheckedContinuation<Bool, Never>] = []
        lock.withLock {
            if ticket == nil { closed = true }
            let owned = slots.values.filter { ticket == nil || $0.ticket == ticket }
            for slot in owned {
                slot.retired = true
                if let task = slot.task { tasks.append(task) }
                if let ready = slot.ready { waiters.append(ready) }
                slot.task = nil
                slot.ready = nil
                slots.removeValue(forKey: slot.identifier)
            }
        }
        // Cancellation handlers retire native requests and the shared export
        // lease synchronously, before a separate actor Cancel event is queued.
        tasks.forEach { $0.cancel() }
        waiters.forEach { $0.resume(returning: false) }
    }
}
