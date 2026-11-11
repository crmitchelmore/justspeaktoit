import Foundation
import SpeakCore
import SpeakDesktop

/// A user-facing failure at the desktop host boundary. Its message is shown
/// verbatim on the status line.
package struct DesktopHostError: LocalizedError, Sendable {
    package let message: String
    package var errorDescription: String? { message }
    package init(message: String) { self.message = message }
}

/// Record-bound playback of one History recording at a time.
package protocol DesktopHostPlayback: AnyObject, Sendable {
    /// Receives terminal status messages with the run revision they belong to.
    func setStatusHandler(_ handler: @escaping @Sendable (_ revision: UInt64, _ message: String) -> Void)
    func isCurrent(revision: UInt64) -> Bool
    func play(recordID: UUID, path: String, knownDuration: TimeInterval?) throws
    func togglePause(recordID: UUID) -> Bool
    /// Only the user's Stop is `announcing` and reports "Playback stopped.";
    /// stopping to make way for another row, a search, recording or import
    /// leaves the status line to that work.
    func stop(announcing: Bool)
    func stop(unless recordID: UUID)
    /// Returns once output is acknowledged silent.
    func stopAndWait() async throws
    func stopSavedAudioAndWait() async throws
    func close() async throws
}

/// Native services and the window presenter a desktop host provides. Every
/// requirement is static because each host owns exactly one native window,
/// credential store and clipboard, reached through a process-wide C ABI.
package protocol DesktopHostPlatform: Sendable {
    /// Persisted automatic text-output choices. Each recording snapshots these
    /// when it starts; the platform decides what they mean.
    associatedtype TextOutputOptions: Codable & Sendable
    static func appSwitchPolicy(_ options: TextOutputOptions?) -> AppSwitchDelivery?
    static func importingAppSwitchPolicy(
        from configuration: DesktopConfiguration, into options: inout TextOutputOptions?
    ) throws -> DesktopConfiguration
    /// The persisted global shortcut.
    associatedtype HotKeySettings: Codable & Sendable
    /// The persisted Read aloud voice.
    associatedtype VoiceOutputSettings: Codable & Sendable
    static func archiveNativePreferences(
        textOutput: TextOutputOptions?, hotKey: HotKeySettings?, voiceOutput: VoiceOutputSettings?
    ) -> DesktopHostNativePreferenceProjection
    static var nativeConfigurationPlatform: DesktopNativeConfigurationCapture.Platform? { get }
    static var voiceConfigurationKeys: Set<String> { get }
    /// Shortcut configuration keys the host applies; see DesktopHostShortcutBindings.swift.
    static var shortcutConfigurationKeys: Set<String> { get }
    static func exportVoiceConfiguration(
        _ voiceOutput: VoiceOutputSettings?, over configuration: DesktopConfiguration
    ) throws -> DesktopConfiguration
    static func importVoiceConfiguration(
        from configuration: DesktopConfiguration, into voiceOutput: inout VoiceOutputSettings?
    ) throws -> DesktopConfiguration
    /// The controller-owned Read aloud task and engine, if the host has one.
    associatedtype ReadAloudState
    /// The field captured when a recording starts, if the host can capture one.
    associatedtype InsertionTarget: Sendable
    /// One automatic output owned by the controller's single output slot.
    associatedtype OutputJob: Sendable
    associatedtype Playback: DesktopHostPlayback

    /// The platform's name in user-facing preview limits, e.g. "Windows".
    static var displayName: String { get }
    /// Where saved API keys live, for the save confirmation.
    static var credentialStoreName: String { get }
    static func matchProfile(_ profiles: [DictationProfile], executablePath: String?) -> DictationProfile?

    // Window presenter. Safe from any thread.
    static func update(_ status: String, transcript: String?, state: Int32)
    /// Native queue-side tickets reject previews across page/record changes, including away/back.
    static func beginCleanupPreview() -> UInt64
    static func cleanupPreview(_ text: String, ticket: UInt64) throws
    static func endCleanupPreview(_ ticket: UInt64)
    static func recordingState(_ state: Int32)
    /// Voice Edit owns an independent Escape reason, as on the Mac.
    static func voiceEditEscape(_ active: Bool)
    static func voiceGenerated(_ presentation: DesktopVoiceResultPresentation)
    static func voiceUsage(_ presentation: DesktopVoiceUsagePresentation)
    static func voiceDiscovery(_ presentation: DesktopVoiceDiscoveryPresentation)
    static func voiceTextImportCancelled(_ requestID: String)
    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool)
    /// Totals for the dashboard (`all` saved records) and the History header
    /// (`visible`, the records the search shows). Sent with every History list.
    static func historyInsights(all: DesktopHistoryInsights, visible: DesktopHistoryInsights)
    static func historyFilters(models: [String], selection: DesktopHistoryFilter)
    static func historyManagement(identifiers: [UUID])
    /// Nil until this host implements the explicit, local issue preview UI.
    static var issueReportActions: DesktopHostIssueReportActions? { get }
    /// The recording HUD's phase for the dictation it follows; `.hidden` hides it.
    static func hud(_ state: DesktopHUDState)
    static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    )
    static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool)
    /// Shows `DesktopHostModels.snapshot` with a catalogue status line.
    static func publishModels(status: String, refreshing: Bool) throws
    /// Updates inactive Local slots without activating a model or emitting a selection.
    static func publishLocalModelPreferences(batch: String?, live: String?) throws

    // Credentials.
    /// Returns "" when no key is saved.
    static func apiKey(name: String) throws -> String
    /// An empty key removes the saved one.
    static func saveAPIKey(_ key: String, name: String) throws

    // Files, clipboard and audio.
    static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging
    /// Creates `directory` readable only by the current user.
    static func preparePrivateDirectory(_ directory: URL) throws
    /// Converts any supported import to canonical PCM16 WAV, returning its duration.
    static func convertAudio(input: URL, output: URL) async throws -> TimeInterval
    /// Opens a saved recording in the user's default application.
    static func openFile(_ url: URL) throws
    static func revealDirectory(_ url: URL) throws
    static func confirmAudioCleanup(id: UUID, count: Int) throws
    static var migrationArchive: DesktopMigrationBackup.Adapter? { get }
    static var migrationInspector: DesktopHostMigrationInspector? { get }
    static var migrationRestorer: DesktopHostMigrationRestorer? { get }
    static func copyToClipboard(_ text: String) throws

    static var comparisonDigest: LocalModelDigestProvider? { get }
    static func comparisonPresentation(_ presentation: DesktopComparisonPresentation)

    // Automatic output and playback.
    /// The job for a finished recording, or nil when no output is possible
    /// (no captured field, or the clipboard is unavailable).
    static func makeOutputJob(options: TextOutputOptions, target: InsertionTarget?) -> OutputJob?
    static func requiresInsertionTarget(_ options: TextOutputOptions) -> Bool
    static func makePlayback() -> Playback
    static func makeRecordingFeedbackLoader() -> (any DesktopRecordingFeedbackLoader)?
    /// Why native session lock/sleep monitoring cannot protect an armed microphone.
    static func handsFreeReadinessFailure() -> String?
    /// Nonblocking. A native operation already committed completes and is
    /// reported; nothing starts afterwards.
    static func cancel(_ job: OutputJob)
    /// True when the job only copies, for the in-progress status line.
    static func isClipboard(_ job: OutputJob) -> Bool
    static var correctionLearningUnavailable: String? { get }
    static func correctionReadback(_ job: OutputJob) -> (any DesktopCorrectionReadback)?
    static var supportsObservationalCorrections: Bool { get }
    /// Local, nonpersistent consent; revocation must not wait for native work.
    @discardableResult
    static func setObservationalCorrectionConsent(_ allowed: Bool, token: UInt64?) -> Bool
    static func observationalCorrectionActionIsCurrent(_ allowed: Bool, token: UInt64) -> Bool

    // Read aloud. Hosts without it keep an empty state.
    static func makeReadAloudState() -> ReadAloudState
    /// Ends Read aloud: the current segment stops and no later one starts.
    static func stopReadAloud(_ state: inout ReadAloudState, playback: Playback)
    /// True while Read aloud is speaking or synthesizing a segment.
    static func isReadingAloud(_ state: ReadAloudState) -> Bool

    // On-device transcription. Hosts without a local runtime keep the defaults
    // and configure no local models.
    /// Controller-owned downloads, progress and runtime for on-device models.
    associatedtype LocalModelsState = Void
    static func makeLocalModelsState() -> LocalModelsState
    static func loadLocalModels(directory: URL) throws -> LocalModelsState
    static func cancelLocalModels(controller: isolated DesktopHostController<Self>)
    /// How status lines name this computer, e.g. "this PC".
    static var localDeviceName: String { get }
    /// Why an on-device model cannot run now, or nil when it can.
    static func localReadiness(_ model: String, controller: isolated DesktopHostController<Self>) -> String?
    static func transcribeLocally(
        _ audio: URL, model: String, language: String?, controller: isolated DesktopHostController<Self>
    ) async throws -> TranscriptionResult
    /// Holds an on-device model for one recording or transcription until
    /// `endLocalUse`, so it cannot be removed meanwhile. Returns the held
    /// identifier, or nil for models the host does not run on-device.
    static func beginLocalUse(_ model: String, controller: isolated DesktopHostController<Self>) -> String?
    static func endLocalUse(_ held: String, controller: isolated DesktopHostController<Self>)
    /// An in-process streaming client for a `DesktopHostModels.localLive`
    /// model, or nil when the host cannot stream it. Throws the user-facing
    /// reason the model cannot run now.
    static func makeLocalLiveClient(
        _ model: String, language: String?, controller: isolated DesktopHostController<Self>
    ) async throws -> (any FinalizingStreamingTranscriptionClient)?

    static func makeLocalCleanup(directory: URL) throws -> DesktopLocalLLMStore?
    static func presentLocalCleanup(
        _ rows: [DesktopLocalLLMStore.Row], status: String, presenter: UnsafeMutableRawPointer?
    )
    static func presentPostProcessing(_ options: DesktopPostProcessing.Options, presenter: UnsafeMutableRawPointer?)

    // Launch at login. Hosts without it keep the defaults, and the switch
    // reads unavailable.
    /// Where the system's own startup settings live, for the switch's note.
    static var loginItemSettingsName: String { get }
    /// The system's registration. `recorded` is the state last reached, for
    /// hosts that cannot read the registration back.
    static func loginItemState(recorded: Bool?) async -> DesktopLoginItemState
    /// Registers or removes the login item and returns the state reached.
    static func setLoginItem(_ enabled: Bool) async throws -> DesktopLoginItemState
    /// Shows the state on General's switch, with the note under it.
    static func showLoginItem(_ state: DesktopLoginItemState, detail: String)

    /// Applies General's app visibility and compact icon to the window and
    /// notification area. Hosts without that shell keep and transfer the values.
    static func applyShell(_ preferences: DesktopShellPreferences)

    // Shortcut text for the status line.
    static var defaultHotKey: HotKeySettings { get }
    /// Appended to the Ready status line.
    static func readyHint(_ hotKey: HotKeySettings) -> String
    /// What finishes a session that `trigger` started.
    static func finishHint(_ hotKey: HotKeySettings, for trigger: HotKeySessionTrigger) -> String
}

package extension DesktopHostPlatform {
    static var issueReportActions: DesktopHostIssueReportActions? { nil }
    static func publishLocalModelPreferences(batch: String?, live: String?) throws {
        throw DesktopHostError(message: "Updating Local model choices is unavailable on this host.")
    }
    static var supportsObservationalCorrections: Bool { false }
    @discardableResult
    static func setObservationalCorrectionConsent(_ allowed: Bool, token: UInt64?) -> Bool { !allowed }
    static func observationalCorrectionActionIsCurrent(_ allowed: Bool, token: UInt64) -> Bool { false }
    static func matchProfile(_ profiles: [DictationProfile], executablePath: String?) -> DictationProfile? {
        ProfileResolver(profiles: profiles).profile(forWindowsExecutablePath: executablePath)
    }
    static func makeLocalCleanup(directory: URL) throws -> DesktopLocalLLMStore? { nil }
    static func presentLocalCleanup(
        _ rows: [DesktopLocalLLMStore.Row], status: String, presenter: UnsafeMutableRawPointer?
    ) {}
    static func presentPostProcessing(_ options: DesktopPostProcessing.Options, presenter: UnsafeMutableRawPointer?) {}
    static func revealDirectory(_ url: URL) throws {
        throw DesktopHostError(message: "Opening recording folders is unavailable on this host.")
    }
    static func confirmAudioCleanup(id: UUID, count: Int) throws {
        throw DesktopHostError(message: "Recording audio cleanup is unavailable on this host.")
    }
    static func makeRecordingFeedbackLoader() -> (any DesktopRecordingFeedbackLoader)? { nil }
    static var comparisonDigest: LocalModelDigestProvider? { LocalModelDigestProvider.platformDefault }
    static func comparisonPresentation(_ presentation: DesktopComparisonPresentation) {}
    static func voiceGenerated(_ presentation: DesktopVoiceResultPresentation) {}
    static func voiceUsage(_ presentation: DesktopVoiceUsagePresentation) {}
    static func voiceDiscovery(_ presentation: DesktopVoiceDiscoveryPresentation) {}
    static func voiceTextImportCancelled(_ requestID: String) {}
    static func handsFreeReadinessFailure() -> String? { "Hands-free is unavailable on this host." }
    static func update(_ status: String) { update(status, transcript: nil, state: -1) }
    static func beginCleanupPreview() -> UInt64 { 0 }
    static func cleanupPreview(_ text: String, ticket: UInt64) throws {
        update("Streaming cleanup preview. The original is saved in History.", transcript: text, state: 2)
    }
    static func endCleanupPreview(_ ticket: UInt64) {}
    static func voiceEditEscape(_ active: Bool) {}
    /// Hosts without a dashboard or History header show no totals.
    static func historyInsights(all: DesktopHistoryInsights, visible: DesktopHistoryInsights) {}
    static func historyFilters(models: [String], selection: DesktopHistoryFilter) {}
    static func historyManagement(identifiers: [UUID]) {}
    /// Hosts without a HUD show dictation progress on the status line only.
    static func hud(_ state: DesktopHUDState) {}
    static var loginItemSettingsName: String { "the system's startup settings" }
    static func loginItemState(recorded: Bool?) async -> DesktopLoginItemState { .unavailable }
    static func setLoginItem(_ enabled: Bool) async throws -> DesktopLoginItemState { .unavailable }
    static func showLoginItem(_ state: DesktopLoginItemState, detail: String) {}
    static func applyShell(_ preferences: DesktopShellPreferences) {}
}
