import Foundation
import SpeakCore
import SpeakDesktop

/// Voice-command preferences captured with a microphone recording, so a settings
/// edit made while it records or finishes cannot change how its transcript expands.
package struct DesktopHostVoiceCommandPolicy: Equatable, Sendable {
    let enabled: Bool
    let triggers: String

    init(_ configuration: DesktopConfiguration) {
        enabled = configuration.enabled("voiceCommandsEnabled")
        triggers = configuration.text("clipboardInsertionTriggers")
    }

    /// A recording without stored preferences keeps canonical defaults, never later settings.
    init(recorded configuration: DesktopConfiguration?) throws {
        try self.init(configuration ?? DesktopConfiguration())
    }
}

extension DesktopHostController {
    /// Runs once per successful provider result, before vocabulary and polish.
    /// History selection and Copy consume saved variants. Microphone recordings
    /// pass the policy frozen at Record; imports and retries use current settings.
    func applyVoiceCommands(
        _ original: DesktopRecordingStore.Record, policy recorded: DesktopHostVoiceCommandPolicy? = nil
    ) async throws -> DesktopRecordingStore.Record {
        guard !closed, !cancellationRequested else { throw CancellationError() }
        try Task.checkCancellation()
        guard let text = original.originalText, original.correctedText == nil else { return original }
        let policy = try recorded ?? DesktopHostVoiceCommandPolicy(configuration())
        let (enabled, triggers) = (policy.enabled, policy.triggers)
        guard enabled, VoiceCommandProcessor.containsClipboardCommand(in: text, customTriggers: triggers) else {
            return original
        }
        let effects = effects
        let task = Task {
            try await DesktopVoiceCommandClipboardRead.run { try await effects.voiceCommandClipboardText() }
        }
        voiceCommandTask = task
        defer { voiceCommandTask = nil }
        let snapshot = try await task.value
        guard !closed, !cancellationRequested else { throw CancellationError() }
        try Task.checkCancellation()
        var record = original
        record.correctedText = VoiceCommandProcessor.process(
            text, enabled: enabled, customTriggers: triggers, clipboardText: snapshot
        )
        // Persist before any later asynchronous correction or remote request.
        try await saveRecord(record)
        return record
    }
}

/// Native clipboard owners can stall or ignore cancellation. Do not hold the
/// host's cancellation/shutdown path waiting for such an owner.
enum DesktopVoiceCommandClipboardRead {
    static let maximumBytes = 1_048_576

    static func run(
        timeout: Duration = .seconds(3),
        failureMessage: String = "Clipboard voice command could not be read. Original transcript and audio retained.",
        timeoutMessage: String = "Clipboard voice command timed out. Original transcript and audio retained.",
        read: @escaping @Sendable () async throws -> String?
    ) async throws -> String? {
        let gate = Gate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.arm(continuation)
                gate.track(Task {
                    do {
                        try Task.checkCancellation()
                        let text = try await read()
                        guard text?.utf8.count ?? 0 <= maximumBytes else {
                            throw DesktopHostError(message: "Clipboard text exceeds the 1 MiB voice-command limit.")
                        }
                        gate.settle(.success(text))
                    } catch {
                        // A native error may contain clipboard-owner text. Never persist it.
                        gate.settle(.failure(error is CancellationError ? CancellationError()
                            : DesktopHostError(message: failureMessage)))
                    }
                })
                gate.track(Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    gate.settle(.failure(DesktopHostError(message: timeoutMessage)))
                })
            }
        } onCancel: { gate.settle(.failure(CancellationError())) }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<String?, Error>?
        private var continuation: CheckedContinuation<String?, Error>?
        private var tasks: [Task<Void, Never>] = []

        func arm(_ continuation: CheckedContinuation<String?, Error>) {
            let settled = lock.withLock { () -> Result<String?, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let settled { continuation.resume(with: settled) }
        }

        func track(_ task: Task<Void, Never>) {
            let cancel = lock.withLock {
                if result != nil { return true }
                tasks.append(task)
                return false
            }
            if cancel { task.cancel() }
        }

        func settle(_ result: Result<String?, Error>) {
            let settled = lock.withLock { () -> (CheckedContinuation<String?, Error>?, [Task<Void, Never>])? in
                guard self.result == nil else { return nil }
                self.result = result
                defer { continuation = nil; tasks = [] }
                return (continuation, tasks)
            }
            guard let (continuation, tasks) = settled else { return }
            continuation?.resume(with: result)
            tasks.forEach { $0.cancel() }
        }
    }
}
