#if os(iOS)
import Foundation
import SpeakCore

/// Runs a downloaded GGUF cleanup model in process.
///
/// The app target implements this with the llama.cpp runtime compiled into it
/// (`SpeakiOSLlama`) and registers it at launch, so SpeakiOSLib and the
/// extensions that link it never carry llama.cpp. Where no engine is
/// registered, a downloaded cleanup model reports itself unavailable rather
/// than falling back to a cloud model or rules cleanup.
public protocol IOSLocalCleanupEngine: AnyObject, Sendable {
    /// The model's raw reply to the SYSTEM and USER messages, loading the
    /// verified file for this run and freeing it afterwards. Throws
    /// `IOSLocalCleanupError`; never returns partial output. Cancelling the
    /// calling task stops loading or generation.
    func complete(modelFile: URL, systemPrompt: String, userMessage: String, timeout: TimeInterval) async throws
        -> String

    /// Stops any running cleanup so its memory is released, for example on a
    /// memory warning. The stopped cleanup keeps its original transcript.
    func releaseMemory()
}

/// The process's cleanup engine, if the host registered one.
public enum IOSLocalCleanupEngines {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var engine: IOSLocalCleanupEngine?
    }

    private static let storage = Storage()

    public static func register(_ engine: IOSLocalCleanupEngine?) {
        storage.lock.lock()
        storage.engine = engine
        storage.lock.unlock()
    }

    public static var current: IOSLocalCleanupEngine? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.engine
    }
}

/// Why a downloaded cleanup model did not apply. Every case keeps the original
/// transcript; none falls back to a cloud model or rules cleanup.
public enum IOSLocalCleanupError: LocalizedError, Equatable {
    case engineUnavailable
    case unknownModel(String)
    case notOfferedOnThisDevice(String)
    case notDownloaded(String)
    case verificationFailed(String)
    case insufficientSpace(neededMB: Int)
    case modelInUse(String)
    case downloadFailed(String)
    case loadFailed(String)
    case timedOut(String)
    case stopped(String)
    case thinkingAloud(String)
    case noUsableAnswer(String)
    case transcriptTooLong(String)
    case runtimeFailed(String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            return "On-device cleanup models only run in the Just Speak to It app. The original transcript was kept."
        case .unknownModel(let identifier):
            return "\"\(identifier)\" is not an on-device cleanup model this app knows. "
                + "The original transcript was kept."
        case .notOfferedOnThisDevice(let name):
            return "\(name) needs more memory than this device has. The original transcript was kept."
        case .notDownloaded(let name):
            return "\(name) is not downloaded. Download it in Settings › Post-Processing. "
                + "The original transcript was kept."
        case .verificationFailed(let name):
            return "\(name) failed its integrity check. Remove it and download it again. "
                + "The original transcript was kept."
        case .insufficientSpace(let neededMB):
            return "Not enough free space. This model needs about \(neededMB) MB."
        case .modelInUse(let name):
            return "\(name) is cleaning up a transcript. Try again when it finishes."
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .loadFailed(let name):
            return "\(name) could not be loaded. Remove it and download it again. The original transcript was kept."
        case .timedOut(let name):
            return "\(name) took too long to clean up this transcript. The original transcript was kept."
        case .stopped(let name):
            return "\(name) was stopped before it finished, for example because memory ran low. "
                + "The original transcript was kept."
        case .thinkingAloud(let name):
            return "\(name) replied with its reasoning instead of a cleaned transcript. "
                + "The original transcript was kept."
        case .noUsableAnswer(let name):
            return "\(name) returned no usable text. The original transcript was kept."
        case .transcriptTooLong(let name):
            return "This transcript is too long for \(name). The original transcript was kept."
        case .runtimeFailed(let name, let code):
            return "\(name) could not clean up this transcript (error \(code)). The original transcript was kept."
        }
    }
}
#endif
