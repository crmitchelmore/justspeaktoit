import Foundation
import SpeakCore
import SpeakDesktop

/// The object a Windows or Linux window callback context resolves to. Both
/// hosts route UI events through the same ordered queues: settings in UI event
/// order and History events through one coalescing dispatcher.
package protocol DesktopNativeEventHolder: AnyObject {
    associatedtype Platform: DesktopNativeWindowPlatform
    var controller: DesktopHostController<Platform> { get }
    /// Persists settings in UI event order; shutdown drains these.
    func enqueueSettings(_ action: @escaping @Sendable () async -> Void)
    /// Joins History selection order, so a click reaches the record selected before it.
    func submitHistoryPlayback(_ event: DesktopHistoryEvent)
    /// Applies a Dictation preferences action, then redisplays the editor.
    func performConfigurationAction(_ action: Int32, values: [String], editorID: String?) async throws
    /// Redisplays Dictation preferences from the saved values.
    func configureConfiguration() async throws
}

package extension DesktopNativeEventHolder {
    /// The ordered History dispatcher both windows use: selection, version,
    /// playback, Read aloud, filters and Voice events reach the controller in
    /// the order the window sent them, coalesced as `DesktopHistoryEvent` says.
    static func makeHistoryEvents(
        _ controller: DesktopHostController<Platform>
    ) -> DesktopEventDispatcher<DesktopHistoryEvent> {
        DesktopEventDispatcher(coalescing: DesktopHistoryEvent.coalesce) { event in
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
                await controller.performVoiceEvent(event) { Platform.voiceTextImported($1, requestID: $0) }
            }
        }
    }

    /// The Voice Output key editor's native callback. `arguments` are its C
    /// strings in ABI order: operation, purpose, identifier, request ID,
    /// selection epoch and secret.
    static func voiceCredentialEvent(_ arguments: [UnsafePointer<CChar>?], context: UnsafeMutableRawPointer?) {
        guard let holder = NativeCallbackContext<Self>.resolve(context) else { return }
        let fields = arguments.map(String.init(nativeOrEmpty:))
        do {
            guard fields.count == 6 else { throw DesktopHostError(message: "The Voice key request was malformed.") }
            let message = try VoiceOutputCredentialMessage(
                operation: fields[0], purpose: fields[1], identifier: fields[2],
                requestID: fields[3], selectionEpoch: fields[4], key: fields[5])
            let controller = holder.controller
            holder.enqueueSettings { await controller.handleVoiceCredential(message) }
        } catch { Platform.update(error.localizedDescription) }
    }

    /// The account Voice key editor's native callback. `arguments` are its C
    /// strings in ABI order: operation, purpose, provider, identifier,
    /// session, epoch, request ID and secret.
    static func voiceProviderCredentialEvent(
        _ arguments: [UnsafePointer<CChar>?], context: UnsafeMutableRawPointer?
    ) {
        guard let holder = NativeCallbackContext<Self>.resolve(context) else { return }
        let fields = arguments.map(String.init(nativeOrEmpty:))
        do {
            guard fields.count == 8 else { throw DesktopHostError(message: "The Voice key request was malformed.") }
            let message = try VoiceProviderCredentialMessage(
                operation: fields[0], purpose: fields[1], providerID: fields[2], identifier: fields[3],
                sessionID: fields[4], epoch: fields[5], requestID: fields[6], key: fields[7])
            let controller = holder.controller
            holder.enqueueSettings { await controller.handleVoiceProviderCredential(message) }
        } catch { Platform.update(error.localizedDescription) }
    }

    /// Voice Output's source, discovery, usage and preference callback.
    /// `strings` are its C strings in ABI order: text, record and path.
    static func voiceSourceEvent(
        action: Int32, source: Int32, strings: [UnsafePointer<CChar>?], context: UnsafeMutableRawPointer?
    ) {
        guard let holder = NativeCallbackContext<Self>.resolve(context) else { return }
        let fields = strings.map(String.init(nativeOrEmpty:))
        do {
            guard fields.count == 3 else { throw DesktopHostError(message: "The Voice Output request was malformed.") }
            let message = try DesktopVoiceSourceMessage(
                action: action, source: source, text: fields[0], record: fields[1], path: fields[2]
            )
            holder.submitVoiceSource(message)
        } catch { Platform.update(error.localizedDescription) }
    }

    /// Routes a validated Voice Output message: History events join the
    /// selection order and everything else is applied in settings order.
    func submitVoiceSource(_ message: DesktopVoiceSourceMessage) {
        let controller = controller
        switch message {
        case .audioFormat(let identifier):
            enqueueSettings {
                await controller.beginVoiceAudioFormatSave(identifier) { saved, failure in
                    guard let saved else { return }
                    Platform.showVoiceAudioFormats(saved,
                        status: failure ?? "Voice file format saved. Generated results keep their captured format.")
                }
            }
        case .discoveryOpen, .discoveryOpenModern, .discoveryRefresh,
             .discoveryClose, .discoveryChoose, .discoveryProvider:
            enqueueSettings { await controller.handleVoiceDiscovery(message) }
        case .event(let event): submitHistoryPlayback(event)
        case .preferences(let options):
            enqueueSettings { await Self.saveVoiceGenerationOptions(options, controller: controller) }
        case .usageReport(let text, let requestID):
            enqueueSettings { await controller.showVoiceUsage(text: text, requestID: requestID) }
        case .usageTracking(let enabled, let requestID):
            enqueueSettings { await controller.saveVoiceUsageTracking(enabled, requestID: requestID) }
        case .synthesisPreferences(let options, let requestID):
            enqueueSettings {
                await Self.saveVoiceSynthesisOptions(options, requestID: requestID, controller: controller)
            }
        }
    }

    private static func saveVoiceGenerationOptions(
        _ options: VoiceGenerationOptions, controller: DesktopHostController<Platform>
    ) async {
        await controller.saveVoiceGenerationOptions(options)
        let saved = await controller.voiceOutputSettings()
        if Platform.nativeVoice.setGenerationOptions(saved.generationOptions.nativeFlags) != 0 {
            Platform.update("The saved Voice Output preferences could not be shown.")
        }
    }

    private static func saveVoiceSynthesisOptions(
        _ options: VoiceSynthesisOptions, requestID: String, controller: DesktopHostController<Platform>
    ) async {
        let saved = await controller.saveVoiceSynthesisOptions(options)
        Platform.showVoiceControls(await controller.voiceOutputSettings(),
            accountInventory: await controller.selectedVoiceAccountInventory)
        if Platform.nativeVoice.finishSynthesisOptions(requestID, saved ? 1 : 0) != 0 {
            Platform.update("The Voice controls save result could not be shown.")
        }
    }

    /// Dictation preferences' native callback. A render acknowledgement
    /// activates its snapshot; an action is applied in settings order and, on
    /// failure, the editor is redisplayed from the saved preferences. Malformed
    /// input is refused synchronously through `errorBuffer`. Returns the C result.
    static func configurationEditorEvent(
        action: Int32, values: [String], context: UnsafeMutableRawPointer?,
        errorBuffer: UnsafeMutablePointer<CChar>?, capacity: Int
    ) -> Int32 {
        guard let holder = NativeCallbackContext<Self>.resolve(context) else { return -1 }
        do {
            switch try DesktopHostConfigurationEditorEvent(action: action, values: values) {
            case .rendered(let id):
                let controller = holder.controller
                holder.enqueueSettings {
                    do { try await controller.activateConfigurationEditorSnapshot(id) } catch {
                        Platform.update(error.localizedDescription)
                    }
                }
            case .action(let action, let values, let editorID):
                holder.enqueueSettings {
                    do {
                        try await holder.performConfigurationAction(action, values: values, editorID: editorID)
                    } catch {
                        Platform.update(error.localizedDescription)
                        do { try await holder.configureConfiguration() } catch {
                            Platform.update(error.localizedDescription)
                        }
                    }
                }
            }
            return 0
        } catch {
            DesktopNativeStrings.copy(error.localizedDescription, into: errorBuffer, capacity: capacity)
            return -1
        }
    }
}

package extension String {
    /// A borrowed native C string, or "" for null.
    init(nativeOrEmpty pointer: UnsafePointer<CChar>?) {
        self = pointer.map { String(cString: $0) } ?? ""
    }
}

/// One native handler slot for a window's event holder, such as the account
/// Voice key editor's callback: it attaches at most one registration and
/// reports a slot that could not be configured or detached on the status line.
/// Both windows' handler setters wait for admitted callbacks to finish before
/// clearing, so a detached registration's box is freed at once.
package final class DesktopNativeHandlerSlot<Holder: DesktopNativeEventHolder>: @unchecked Sendable {
    private let slot: NativeCallbackSlot<Holder>
    private let name: String

    /// `name` reads as the subject of the status line, e.g. "The account Voice key callback".
    /// `set` installs the C handler with a context, or clears it when passed nil;
    /// clearing must return only after every running callback has finished.
    package init(_ name: String, quiescentSet set: @escaping (UnsafeMutableRawPointer?) -> Bool) {
        self.name = name
        slot = NativeCallbackSlot(attach: { set($0) }, detach: { set(nil) ? .quiescent : .refused })
    }

    package func begin(_ holder: Holder) throws -> NativeCallbackContext<Holder> {
        guard let registration = slot.begin(holder) else {
            throw DesktopHostError(message: "\(name) could not be configured.")
        }
        return registration
    }

    /// Callback forwarding never takes the slot's lock or awaits work.
    package func end(_ registration: NativeCallbackContext<Holder>) {
        if !slot.end(registration) { Holder.Platform.update("\(name) could not be detached safely.") }
    }
}

package extension DesktopNativeEventHolder {
    /// Preferences › General › Edit raw configuration. Runs in settings order,
    /// so an Apply follows the edits before it, then shows the outcome in the
    /// window. False for other events.
    func handleRawConfigurationEvent(_ event: DesktopNativeWindowEvent, value: String, index: Int32) -> Bool {
        guard event == .rawConfiguration else { return false }
        guard let action = DesktopRawConfigurationAction(rawValue: index) else { return true }
        let controller = self.controller
        enqueueSettings {
            Platform.rawConfiguration(await controller.rawConfiguration(action, text: value))
        }
        return true
    }
}
