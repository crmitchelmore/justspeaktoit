import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// The window's event numbers, decoded once: events shared with Windows,
/// Linux-only events, comparison window events and unknown numbers.
typealias LinuxWindowEventCode = DesktopNativeWindowEventCode<DesktopNativeLinuxEvent>

/// The GTK window's event callback, on the GTK main thread.
func linuxWindowEvent(
    _ event: Int32, _ text: UnsafePointer<CChar>?, _ index: Int32, _ context: UnsafeMutableRawPointer?
) {
    guard let holder = NativeCallbackContext<LinuxEventContext>.resolve(context) else { return }
    let value = text.map(String.init(cString:)) ?? ""
    switch LinuxWindowEventCode(event) {
    case .shared(let event): linuxSharedEvent(event, value: value, index: index, holder: holder)
    case .host(let event): linuxHostEvent(event, value: value, slot: Int(index), holder: holder)
    case .comparison(let event):
        holder.enqueueSettings { await holder.controller.enqueueComparisonEvent(event, text: value, index: index) }
    case .unknown:
        // A newer native window may report an event this build does not handle.
        break
    }
}

private func linuxSharedEvent(
    _ event: DesktopNativeWindowEvent, value: String, index: Int32, holder: LinuxEventContext
) {
    let slot = Int(index)
    if linuxIssueReportEvent(event, value: value, index: index, holder: holder) { return }
    if linuxActionEvent(event, value: value, slot: slot, holder: holder) { return }
    if linuxSettingsSearchEvent(event, value: value, slot: slot, holder: holder) { return }
    if linuxSessionEvent(event, value: value, slot: slot, holder: holder) { return }
    if linuxHistoryManagementEvent(event, value: value, slot: slot, holder: holder) { return }
    if linuxHistoryEvent(event, value: value, slot: slot, holder: holder) { return }
    _ = linuxSettingsEvent(event, value: value, slot: slot, holder: holder)
    // Otherwise a shared event this window never sends, such as Windows's closing window.
}

private func linuxHostEvent(
    _ event: DesktopNativeLinuxEvent, value: String, slot: Int, holder: LinuxEventContext
) {
    if linuxHostActionEvent(event, value: value, slot: slot, holder: holder) { return }
    if linuxReadAloudEvent(event, value: value, slot: slot, holder: holder) { return }
    if linuxLocalModelEvent(event, value: value, slot: slot, holder: holder) { return }
    if linuxCloudSyncEvent(event, value: value, slot: slot, holder: holder) { return }
    if linuxAppearanceEvent(event, slot: slot, holder: holder) { return }
    _ = linuxHostSettingsEvent(event, value: value, slot: slot, holder: holder)
}

/// Action-shortcut destinations without a page of their own. Returns false for others.
private func linuxActionEvent(
    _ event: DesktopNativeWindowEvent, value: String, slot: Int, holder: LinuxEventContext
) -> Bool {
    switch event {
    case .quickVoice:
        holder.enqueueSettings { await holder.controller.selectQuickVoice(slot) }
    case .speakClipboard:
        holder.enqueueSettings { await holder.controller.readClipboardAloud() }
    case .speechPause:
        holder.enqueueSettings { await holder.controller.pauseResumeSpeech() }
    case .pasteLastHistory:
        holder.pasteLastHistory()
    default: return false
    }
    return true
}

/// Linux-only actions, dialogs and the command-line toggle. Returns false for others.
private func linuxHostActionEvent(
    _ event: DesktopNativeLinuxEvent, value: String, slot: Int, holder: LinuxEventContext
) -> Bool {
    switch event {
    case .profiles: linuxProfilesEvent(value, holder: holder)
    case .commandToggle: holder.shortcutToggle(modelIndex: slot, deviceID: value)
    case .actionShortcutEdit:
        linuxActionShortcutEdit(value, holder: holder)
    case .speakSelectedText:
        holder.speakSelectedText()
    case .apiKeys:
        linuxRequestDialog(jsti_window_request_api_keys(),
                           refusal: "API Keys could not be opened. Try again when the app is idle.")
    case .permissions:
        linuxRequestDialog(jsti_window_request_permissions(),
                           refusal: "Permissions could not be opened. Try again after closing other dialogs.")
    default: return false
    }
    return true
}

/// Reports a native dialog request the window refused.
private func linuxRequestDialog(_ status: Int32, refusal: String) {
    if status != 0 { LinuxHostPlatform.update(refusal) }
}

/// Recording, import, copy and lifecycle events. Returns false for others.
private func linuxSessionEvent(
    _ event: DesktopNativeWindowEvent, value: String, slot: Int, holder: LinuxEventContext
) -> Bool {
    let controller = holder.controller
    switch event {
    case .toggleRecording:
        // Record in this window: its own window is focused, so there is no
        // field to paste into. The transcript is saved and offered for Copy.
        let selection = holder.recordingSettings(modelIndex: slot)
        Task {
            let saved = await selection.value
            await controller.toggleCaptured(
                target: nil, modelIndex: slot, deviceID: value,
                textOutput: saved.textOutput, profile: saved.profile
            )
        }
    case .importAudio:
        let pending = holder.currentSettingsTask
        Task {
            await pending?.value
            await controller.importAudio(path: value, modelIndex: slot)
        }
    case .copyTranscript: holder.copyDisplayed()
    case .ready: linuxReady(holder)
    case .cancel: linuxCancelOperation(value, holder: holder)
    case .userAbsent: Task { await controller.handsFreeUserAbsent(value) }
    case .refreshModels: Task { await controller.refreshModels(force: true) }
    default: return false
    }
    return true
}

/// History list, export and playback events. Returns false for others.
private func linuxHistoryManagementEvent(
    _ event: DesktopNativeWindowEvent, value: String, slot: Int, holder: LinuxEventContext
) -> Bool {
    if linuxMigrationEvent(event, value: value, slot: slot, holder: holder) { return true }
    switch event {
    case .historyFilters: holder.submitHistoryPlayback(.filter(value))
    case .historyDelete:
        let controller = holder.controller
        holder.enqueueSettings { await controller.beginHistoryDeletion(value, deleteAudio: slot == 1) }
    case .historyLoadMore: Task { await holder.controller.loadMoreHistory() }
    case .recordingsFolder: Task { await holder.controller.revealRecordingsDirectory() }
    case .audioCleanup:
        holder.enqueueSettings { await holder.controller.beginAudioCleanupConfirmation() }
    case .audioCleanupResponse:
        holder.enqueueSettings { await holder.controller.answerAudioCleanup(value, delete: slot == 1) }
    default: return false
    }
    return true
}

private func linuxHistoryEvent(
    _ event: DesktopNativeWindowEvent, value: String, slot: Int, holder: LinuxEventContext
) -> Bool {
    let controller = holder.controller
    switch event {
    case .selectHistory: holder.selectHistory(value)
    case .retryHistory: Task { await controller.retryHistory(value) }
    case .exportHistory:
        // The window captured the text and version at the Export click; the
        // snapshot returns that capture while this event runs.
        do {
            let text = try LinuxWindow.displayedTranscript()
            let variant: DesktopTranscriptVariant = slot == 0 ? .processed : .original
            Task { await controller.exportHistory(text: text, variant: variant, path: value) }
        } catch { LinuxHostPlatform.update(error.localizedDescription) }
    case .openHistoryAudio: Task { await controller.openHistoryAudio(value) }
    case .searchHistory: holder.search(value)
    case .transcriptVersion:
        holder.selectVersion(slot == 1 ? .original : .processed, identifier: value)
    case .playbackToggle: holder.submitHistoryPlayback(.playPause(value))
    case .playbackStop: holder.submitHistoryPlayback(.stop)
    default: return false
    }
    return true
}

/// Settings events, applied in order. Returns false for unknown events.
/// General › Appearance: the window already shows the scheme; this keeps it.
/// General › Launch at login: the switch waits for the state reached.
private func linuxAppearanceEvent(_ event: DesktopNativeLinuxEvent, slot: Int, holder: LinuxEventContext) -> Bool {
    let controller = holder.controller
    switch event {
    case .appearance:
        if let appearance = DesktopAppearance(rawValue: slot) {
            holder.enqueueSettings { await controller.saveAppearance(appearance) }
        }
    case .loginItem: holder.enqueueSettings { await controller.setLaunchAtLogin(slot == 1) }
    case .automation:
        holder.enqueueSettings { await LinuxAutomationSwitch.setEnabled(slot == 1, holder: holder) }
    default: return false
    }
    return true
}

/// Shared settings events, applied in order. Returns false for others.
private func linuxSettingsEvent(
    _ event: DesktopNativeWindowEvent, value: String, slot: Int, holder: LinuxEventContext
) -> Bool {
    let controller = holder.controller
    switch event {
    case .saveCredential: holder.enqueueSettings { await controller.beginKeySave(value, modelIndex: slot) }
    case .selectModel: holder.enqueueSettings { await controller.selectModel(slot) }
    case .selectMicrophone: holder.enqueueSettings { await controller.selectMicrophone(value) }
    case .vocabularyAction, .vocabularyLoad, .vocabularyRecording:
        linuxVocabularyEvent(event.rawValue, payload: value, kind: slot, holder: holder)
    default: return false
    }
    return true
}

/// Linux-only settings events, applied in order. Returns false for others.
private func linuxHostSettingsEvent(
    _ event: DesktopNativeLinuxEvent, value: String, slot: Int, holder: LinuxEventContext
) -> Bool {
    let controller = holder.controller
    switch event {
    case .textOutput:
        let options: LinuxTextOutputOptions
        do { options = try LinuxTextOutputOptions(nativeMethod: slot, payload: value) } catch {
            LinuxHostPlatform.update("The text output choice could not be read. Reopen preferences and try again.")
            return true
        }
        holder.enqueueSettings {
            await controller.saveTextOutput(options)
            LinuxWindow.textOutput(await controller.textOutputOptions(), hint: holder.shortcuts.hint)
        }
    case .postProcessing:
        linuxPostProcessingEvent(value, slot: slot, holder: holder)
    case .azureResource:
        // Checked before it is queued, with the shared rules the live clients
        // apply, so a saved endpoint can never fail later.
        let endpoint: String
        do {
            endpoint = try DesktopHostAzureResource.normalized(value)
        } catch {
            LinuxHostPlatform.update(error.localizedDescription)
            return true
        }
        holder.enqueueSettings {
            await controller.saveAzureResourceEndpoint(endpoint)
            _ = jsti_window_set_azure_resource(await controller.azureResourceEndpoint())
        }
    case .shortcutStyle:
        guard LinuxHotKeySettings.styles.indices.contains(slot) else { break }
        let hotKey = LinuxHotKeySettings(style: LinuxHotKeySettings.styles[slot].rawValue)
        holder.gestures.configure(style: hotKey.activation)
        holder.enqueueSettings { await controller.saveHotKey(hotKey) }
    case .recordingsLocation:
        holder.enqueueSettings { await controller.chooseRecordingsDirectory(value) }
    default: return false
    }
    return true
}

// Startup dispatch keeps smoke-test/screenshot/ready paths in one lifecycle function.
private func linuxReady(_ holder: LinuxEventContext) { // swiftlint:disable:this function_body_length
    if let check = holder.windowCheck {
        Thread.detachNewThread {
            do { try check() } catch { holder.smokeTestFailure = error }
            jsti_window_request_close()
        }
        return
    }
    if let directory = holder.screenshotDirectory {
        let controller = holder.controller
        Task {
            await controller.ready()
            await controller.refreshLoginItem()
            LinuxWindow.textOutput(
                await controller.textOutputOptions(),
                hint: LinuxHostPlatform.session.shortcutAdvice(command: "justspeaktoit")
            )
            do {
                try directory.withCString { path in
                    try LinuxNative.call { jsti_window_screenshot_tour(path, $0, $1) }
                }
            } catch {
                holder.smokeTestFailure = error
                jsti_window_request_close()
            }
        }
        return
    }
    guard holder.smokeTest else {
        let controller = holder.controller
        let ready = Task { await controller.ready() }
        holder.markReady(ready)
        holder.enqueueSettings {
            await ready.value
            await controller.refreshLoginItem()
            await LinuxAutomationSwitch.restore(holder)
            LinuxOnboarding.openIfNeeded(holder)
        }
        LinuxCloudSync.start(holder, after: ready)
        holder.shortcuts.start(holder)
        do { try holder.microphones.start() } catch {
            LinuxHostPlatform.update("Microphone changes will not be noticed: \(error.localizedDescription)")
        }
        return
    }
    do {
        LinuxWindow.textOutput(.init(), hint: LinuxHostPlatform.session.shortcutAdvice(command: "justspeaktoit"))
        // Capture the laid-out startup window before the self-test changes it.
        if let path = ProcessInfo.processInfo.environment["JSTI_UI_SNAPSHOT_PATH"] {
            try path.withCString { path in try LinuxNative.call { jsti_window_save_snapshot(path, $0, $1) } }
        }
        try LinuxNative.call { jsti_window_self_test($0, $1) }
    } catch { holder.smokeTestFailure = error }
    jsti_window_request_close()
}

/// Copy the clicked identity before leaving GTK; never select a substitute row.
private func linuxIssueReportEvent(
    _ event: DesktopNativeWindowEvent, value: String, index: Int32, holder: LinuxEventContext
) -> Bool {
    if event == .historyIssueReport {
        Task { _ = await holder.controller.beginIssueReport(value) }
        return true
    }
    guard event.isIssueReportAction else { return false }
    guard let ticket = UUID(uuidString: value) else { return true }
    if event == .issueReportClose {
        holder.cancelIssueTasks(ticket: ticket)
        Task { await holder.controller.cancelIssueReport(ticket) }
        return true
    }
    holder.issueTask(ticket: ticket) {
        guard !Task.isCancelled else { return }
        switch event {
        case .issueReportInclude: await holder.controller.setIssueReportIncludesDiagnostics(index != 0, ticket: ticket)
        case .issueReportCopy: await holder.controller.copyIssueReport(ticket)
        case .issueReportSave: _ = await holder.controller.exportIssueReport(ticket)
        case .issueReportOpen: await holder.controller.openIssueReport(ticket)
        default: break
        }
    }
    return true
}
