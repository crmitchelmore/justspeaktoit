import Foundation

/// The app-side operations behind the automation verbs.
///
/// Each platform's app implements this once, over the same managers its UI
/// drives. `AutomationCommandDispatcher` owns everything that must behave the
/// same on every platform — options no build applies yet, file arguments, and
/// how failures map onto the wire's error codes — so a new automation verb is a
/// new requirement here, and no platform compiles until it answers it.
///
/// Requirements are `async` so a main-actor (macOS) or actor-isolated (Windows)
/// host can satisfy them directly; the dispatcher hops to the host's isolation.
public protocol AutomationCommandHost: AnyObject, Sendable {
    /// `sessionActive` and `appVersion` for `status`.
    func automationStatus() async -> AutomationResult
    /// At most `limit` persisted history entries, newest first. Reads the whole
    /// history rather than a UI page, and waits for an initial load.
    func automationHistory(limit: Int) async -> [AutomationHistoryEntry]
    /// Transcribes an existing local file that has already passed
    /// `AutomationRequestPolicy.audioFile(for:)`. Provider failures are thrown as
    /// `transcription_failed`; the file is only ever read.
    func automationTranscribeFile(at url: URL) async throws -> AutomationResult
    /// Starts the same dictation pipeline as the hotkey and returns once the
    /// session is live. Throws `AutomationError.dictationAlreadyRunning` when busy.
    func automationStartDictation() async throws -> AutomationResult
    /// Stops the active session and returns its transcript. Throws
    /// `AutomationError.noDictationRunning` when nothing is recording.
    func automationStopDictation() async throws -> AutomationResult
}

/// Maps one validated automation request onto an `AutomationCommandHost`.
public enum AutomationCommandDispatcher {
    public static func response(
        to request: AutomationRequest,
        host: some AutomationCommandHost
    ) async -> AutomationResponse {
        do {
            try AutomationRequestPolicy.rejectUnappliedOptions(in: request)
            let result: AutomationResult
            switch request.command {
            case .status:
                result = await host.automationStatus()
            case .history:
                result = AutomationResult(entries: await host.automationHistory(limit: request.resolvedLimit))
            case .transcribeFile:
                result = try await host.automationTranscribeFile(at: AutomationRequestPolicy.audioFile(for: request))
            case .startDictation:
                result = try await host.automationStartDictation()
            case .stopDictation:
                result = try await host.automationStopDictation()
            }
            return .success(id: request.id, command: request.command, result: result)
        } catch let error as AutomationError {
            return .failure(id: request.id, command: request.command, error: error)
        } catch {
            // Provider errors carry URLs and occasionally request context; surface
            // the localized description only, never the underlying payload.
            return .failure(
                id: request.id,
                command: request.command,
                error: AutomationError(code: .internalError, message: error.localizedDescription)
            )
        }
    }
}

/// Request rules every app host applies before running a command.
public enum AutomationRequestPolicy {
    /// Fails loudly for wire fields no build can honour yet.
    ///
    /// `provider` and `profile` are part of the schema so a later app version can
    /// apply them without a breaking change, but accepting them silently would
    /// report success for an override that never took effect. Shared so every
    /// platform keeps rejecting them until all of them apply them.
    public static func rejectUnappliedOptions(in request: AutomationRequest) throws {
        if request.provider != nil {
            throw AutomationError(
                code: .invalidArgument,
                message: "This app version cannot override the transcription provider per request. "
                    + "Change the provider in Settings."
            )
        }
        if request.profile != nil {
            throw AutomationError(
                code: .invalidArgument,
                message: "This app version cannot select a dictation profile per request. "
                    + "Choose the profile in the app."
            )
        }
    }

    /// The file a `transcribe_file` request names, once it exists, is not a
    /// directory and is within the automation size cap.
    ///
    /// Hosts may apply stricter provider limits of their own, but never looser.
    public static func audioFile(
        for request: AutomationRequest,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let path = request.path else {
            throw AutomationError(code: .invalidArgument, message: "transcribe_file requires a file path.")
        }
        let url = URL(fileURLWithPath: path)
        #if os(Windows)
        // Foundation renders a drive path's URL as "/C:/…"; hand the file system
        // the native path exactly as the client resolved it.
        let fileSystemPath = path
        #else
        let fileSystemPath = url.path
        #endif
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileSystemPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AutomationError(code: .fileNotFound, message: "No audio file at \(url.lastPathComponent).")
        }
        let size = (try? fileManager.attributesOfItem(atPath: fileSystemPath)[.size] as? Int) ?? 0
        guard size <= AutomationLimits.maxAudioFileBytes else {
            throw AutomationError(
                code: .fileTooLarge,
                message: "\(url.lastPathComponent) is larger than the "
                    + "\(AutomationLimits.maxAudioFileBytes / (1024 * 1024)) MB automation limit."
            )
        }
        return url
    }
}

extension AutomationError {
    /// `start_dictation` while a session is recording or still finishing.
    public static let dictationAlreadyRunning = AutomationError(
        code: .alreadyRecording,
        message: "A dictation session is already running. Stop it before starting another."
    )

    /// `stop_dictation` with nothing recording.
    public static let noDictationRunning = AutomationError(
        code: .notRecording,
        message: "No dictation session is running."
    )
}

extension AutomationHistoryEntry {
    /// The word count every platform reports for an entry's text.
    public static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
