import Foundation
import CWindowsSupport
import CWindowsSelfTest
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

/// The window's event numbers, decoded once: events shared with Linux,
/// Windows-only events, comparison window events and unknown numbers.
typealias WindowsWindowEventCode = DesktopNativeWindowEventCode<DesktopNativeWindowsEvent>

/// The window's event callback, on the UI thread. `text` is borrowed until it returns.
func windowEvent(_ event: Int32, _ text: UnsafePointer<CChar>?, _ index: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let holder = NativeCallbackContext<WindowsEventContext>.resolve(context) else { return }
    let value = text.map(String.init(cString:)) ?? ""
    switch WindowsWindowEventCode(event) {
    case .shared(let event): sharedWindowEvent(event, value: value, index: Int(index), holder: holder)
    case .host(let event): windowsOnlyEvent(event, value: value, index: Int(index), holder: holder)
    case .comparison(let event):
        let controller = holder.controller
        holder.enqueueSettings { await controller.enqueueComparisonEvent(event, text: value, index: index) }
    case .unknown:
        // A newer native window may report an event this build does not handle.
        break
    }
}

private func sharedWindowEvent(
    _ event: DesktopNativeWindowEvent, value: String, index: Int, holder: WindowsEventContext
) {
    if recordingWindowEvent(event, value: value, index: index, holder: holder) { return }
    if transcriptEvent(event, value: value, holder: holder) { return }
    if historyWindowEvent(event, value: value, holder: holder) { return }
    if windowsHistoryManagementEvent(event, value: value, index: index, holder: holder) { return }
    if issueReportWindowEvent(event, value: value, included: index == 1, holder: holder) { return }
    if actionWindowEvent(event, value: value, holder: holder) { return }
    if holder.settingsSearch.handle(event, query: value, row: index) { return }
    if inputWindowEvent(event, value: value, index: index, holder: holder) { return }
    // Otherwise a shared event this window never sends, such as Linux's closing window.
}

/// Vocabulary and gesture-style shortcut events. False for others.
private func inputWindowEvent(
    _ event: DesktopNativeWindowEvent, value: String, index: Int, holder: WindowsEventContext
) -> Bool {
    switch event {
    case .vocabularyAction, .vocabularyLoad, .vocabularyRecording:
        windowsVocabularyEvent(event.rawValue, payload: value, kind: index, holder: holder)
    case .shortcutDown: hotKeyDown(value: value, index: index, holder: holder)
    case .shortcutUp: holder.hotKeys.keyUp()
    default: return false
    }
    return true
}

private func windowsOnlyEvent(
    _ event: DesktopNativeWindowsEvent, value: String, index: Int, holder: WindowsEventContext
) {
    let controller = holder.controller
    switch event {
    case .error: WindowsNative.update(value)
    case .profiles: holder.openProfiles()
    case .hotKeyDeadline: holder.hotKeys.deadlineReached()
    case .readAloud: readAloudEvent(value, holder: holder)
    case .automation: automationEvent(requested: value == "1", holder: holder)
    case .appearance: WindowsPresentation.appearanceEvent(value, holder: holder)
    case .loginItem: holder.enqueueSettings { await controller.setLaunchAtLogin(value == "1") }
    case .speakSelectedText:
        do {
            let target = try WindowsInsertionTarget.captureSelection()
            holder.enqueueSettings {
                await controller.readVoiceSource(.externalSelection) { try await target.selectedText() }
            }
        } catch { WindowsNative.update("Read aloud failed: \(error.localizedDescription)") }
    case .voiceEdit: WindowsVoiceEdit.toggle(holder)
    }
}

/// Record, import, model, microphone and lifecycle events. False for others.
private func recordingWindowEvent(
    _ event: DesktopNativeWindowEvent, value: String, index: Int, holder: WindowsEventContext
) -> Bool {
    let controller = holder.controller
    switch event {
    case .toggleRecording:
        // Capture synchronously before an actor hop or another app gains focus.
        // No external field focused is not an error here: the transcript is
        // still saved and offered for Copy.
        let captured = try? WindowsInsertionTarget.capture()
        toggleRecording(
            controller, target: captured,
            event: holder.recordingEvent(modelIndex: index, executablePath: captured?.executablePath),
            modelIndex: index, deviceID: value
        )
    case .importAudio:
        let pendingSettings = holder.currentSettingsTask
        Task {
            await pendingSettings?.value
            await controller.importAudio(path: value, modelIndex: index)
        }
    case .saveCredential: saveKeyEvent(value, index: index, holder: holder)
    case .selectModel: holder.enqueueSettings { await controller.selectModel(index) }
    case .ready: ready(holder)
    case .selectMicrophone: holder.enqueueSettings { await controller.selectMicrophone(value) }
    case .cancel: windowsCancelOperation(value, holder: holder)
    case .userAbsent: Task { await controller.handsFreeUserAbsent(value) }
    case .refreshModels: Task { await controller.refreshModels(force: true) }
    default: return false
    }
    return true
}

/// Like Copy, Read aloud captures the displayed text on the UI thread, paired
/// with the record ID its event carries.
private func readAloudEvent(_ identifier: String, holder: WindowsEventContext) {
    do {
        let text = try WindowsNative.displayedTranscript()
        holder.submitHistoryPlayback(.readAloud(identifier, text: text))
    } catch { WindowsNative.update(error.localizedDescription) }
}

/// A gesture-style shortcut press on the UI thread.
private func hotKeyDown(value: String, index: Int, holder: WindowsEventContext) {
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
}

// Copy and version events read the displayed version here, on the UI thread,
// so it is paired with the record ID the same event carries. Playback events
// carry the selected record ID for the same reason, in the selection order.
private func transcriptEvent(_ event: DesktopNativeWindowEvent, value: String, holder: WindowsEventContext) -> Bool {
    switch event {
    case .copyTranscript:
        let variant = WindowsNative.displayedTranscriptVariant()
        do {
            let text = try WindowsNative.displayedTranscript()
            holder.copyTranscript(text, variant: variant)
        } catch { WindowsNative.update(error.localizedDescription) }
    case .closing:
        holder.cancelIssueReports()
        holder.microphoneMonitor?.cancel()
    case .searchHistory: holder.search.submit(value)
    case .transcriptVersion:
        if let variant = WindowsNative.displayedTranscriptVariant() {
            holder.selectHistoryVersion(variant, identifier: value)
        }
    case .playbackToggle: holder.submitHistoryPlayback(.playPause(value))
    case .playbackStop: holder.submitHistoryPlayback(.stop)
    default: return false
    }
    return true
}

/// History selection, retry, export, audio and paging events. False for others.
private func historyWindowEvent(_ event: DesktopNativeWindowEvent, value: String, holder: WindowsEventContext) -> Bool {
    let controller = holder.controller
    switch event {
    case .selectHistory: holder.selectHistory(value)
    case .retryHistory: Task { await controller.retryHistory(value) }
    case .exportHistory: exportHistoryWindowEvent(value, holder: holder)
    case .openHistoryAudio: Task { await controller.openHistoryAudio(value) }
    case .historyLoadMore: Task { await controller.loadMoreHistory() }
    default: return false
    }
    return true
}

/// Action shortcut destinations without a page of their own. False for others.
private func actionWindowEvent(_ event: DesktopNativeWindowEvent, value: String, holder: WindowsEventContext) -> Bool {
    let controller = holder.controller
    switch event {
    case .quickVoice:
        guard let slot = Int(value) else { return true }
        holder.enqueueSettings { await controller.selectQuickVoice(slot) }
    case .pasteLastHistory: holder.pasteLastHistory()
    case .speakClipboard: holder.enqueueSettings { await controller.readClipboardAloud() }
    case .speechPause: holder.enqueueSettings { await controller.pauseResumeSpeech() }
    default: return false
    }
    return true
}

// These tasks may suspend in a chooser/browser. Never queue them ahead of
// Close or a replacement preview in the serialized settings/history workers.
private func issueReportWindowEvent(
    _ event: DesktopNativeWindowEvent, value: String, included: Bool, holder: WindowsEventContext
) -> Bool {
    let controller = holder.controller
    if event == .historyIssueReport {
        holder.submitIssueReport(ticket: UUID()) { await controller.beginIssueReport(value) }
        return true
    }
    guard event.isIssueReportAction else { return false }
    guard let ticket = UUID(uuidString: value) else { return true }
    if event == .issueReportClose {
        holder.cancelIssueReports(ticket: ticket)
        Task { await controller.cancelIssueReport(ticket) }
        return true
    }
    holder.submitIssueReport(ticket: ticket) {
        switch event {
        case .issueReportInclude: await controller.setIssueReportIncludesDiagnostics(included, ticket: ticket)
        case .issueReportCopy: await controller.copyIssueReport(ticket)
        case .issueReportSave: await controller.exportIssueReport(ticket)
        case .issueReportOpen: await controller.openIssueReport(ticket)
        default: break
        }
    }
    return true
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
