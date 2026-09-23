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
    func stop()
    func stop(unless recordID: UUID)
    /// Returns once output is acknowledged silent.
    func stopAndWait() async throws
    func close() async throws
}

/// Native services and the window presenter a desktop host provides. Every
/// requirement is static because each host owns exactly one native window,
/// credential store and clipboard, reached through a process-wide C ABI.
package protocol DesktopHostPlatform: Sendable {
    /// Persisted automatic text-output choices. Each recording snapshots these
    /// when it starts; the platform decides what they mean.
    associatedtype TextOutputOptions: Codable & Sendable
    /// The persisted global shortcut.
    associatedtype HotKeySettings: Codable & Sendable
    /// The field captured when a recording starts, if the host can capture one.
    associatedtype InsertionTarget: Sendable
    /// One automatic output owned by the controller's single output slot.
    associatedtype OutputJob: Sendable
    associatedtype Playback: DesktopHostPlayback

    /// The platform's name in user-facing preview limits, e.g. "Windows".
    static var displayName: String { get }
    /// Where saved API keys live, for the save confirmation.
    static var credentialStoreName: String { get }

    // Window presenter. Safe from any thread.
    static func update(_ status: String, transcript: String?, state: Int32)
    static func recordingState(_ state: Int32)
    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool)
    static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    )
    static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool)
    /// Shows `DesktopHostModels.snapshot` with a catalogue status line.
    static func publishModels(status: String, refreshing: Bool) throws

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
    static func copyToClipboard(_ text: String) throws

    // Automatic output and playback.
    /// The job for a finished recording, or nil when no output is possible
    /// (no captured field, or the clipboard is unavailable).
    static func makeOutputJob(options: TextOutputOptions, target: InsertionTarget?) -> OutputJob?
    static func makePlayback() -> Playback
    /// Nonblocking. A native operation already committed completes and is
    /// reported; nothing starts afterwards.
    static func cancel(_ job: OutputJob)
    /// True when the job only copies, for the in-progress status line.
    static func isClipboard(_ job: OutputJob) -> Bool

    // Shortcut text for the status line.
    static var defaultHotKey: HotKeySettings { get }
    /// Appended to the Ready status line.
    static func readyHint(_ hotKey: HotKeySettings) -> String
    /// What finishes a session that `trigger` started.
    static func finishHint(_ hotKey: HotKeySettings, for trigger: HotKeySessionTrigger) -> String
}

package extension DesktopHostPlatform {
    package static func update(_ status: String) { update(status, transcript: nil, state: -1) }
}
