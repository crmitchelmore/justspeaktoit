import Foundation

// MARK: - Watch Capture Queue File
//
// The persisted transfer queue, kept as a JSON array of `WatchCapture`. Like
// the active-capture marker, a damaged file is never mistaken for an empty
// queue and never overwritten: it may still list captures whose audio is
// waiting on the watch.

/// What is on disk where the capture queue lives.
public enum WatchCaptureQueueLoad: Equatable, Sendable {
    /// No queue yet: nothing has been recorded.
    case absent
    case loaded([WatchCapture])
    /// The file exists but could not be read, for example while data
    /// protection still locks it. Possibly transient: leave it and retry.
    case unreadable(reason: String)
    /// The file was read but does not decode. It will not get better.
    case corrupt(reason: String)
}

/// Why the queue is not being saved normally, for the watch UI to show.
public enum WatchCaptureQueueIssue: Equatable, Sendable {
    /// The saved queue could not be read yet. Saving waits until a reload succeeds.
    case unreadable
    /// The saved queue was damaged and is kept under another name; a new queue was started.
    case setAside(URL)
    /// The saved queue is damaged and could not be set aside. Saving waits until a reload succeeds.
    case damaged
    /// The last change could not be saved; the previous saved state stands.
    case saveFailed

    /// While true, saving would replace a queue that could not be read.
    public var blocksSaving: Bool {
        switch self {
        case .unreadable, .damaged: return true
        case .setAside, .saveFailed: return false
        }
    }

    public var message: String {
        switch self {
        case .unreadable:
            return "Saved recordings couldn't be read yet. New recordings are kept until they can be."
        case .setAside:
            return "The saved recordings list was damaged and has been set aside. Its audio is still on the watch."
        case .damaged:
            return "The saved recordings list is damaged. New recordings are kept until it can be set aside."
        case .saveFailed:
            return "A recording's status couldn't be saved. It will be retried."
        }
    }
}

public enum WatchCaptureQueueFileError: LocalizedError, Equatable {
    /// `save` refuses to replace a queue it could not read.
    case damagedQueue

    public var errorDescription: String? {
        switch self {
        case .damagedQueue: return "The saved recordings list could not be read."
        }
    }
}

/// File-backed capture queue. `open()` decides what a fresh queue starts with
/// and records any `issue`; `save` refuses while that issue blocks saving.
/// A new instance reading the same URL models app relaunch.
@MainActor
public final class WatchCaptureQueueFile {
    private let fileURL: URL

    /// Set by `open()` when the saved queue was not loaded normally, and by
    /// `save` when a write fails. Cleared by an `open()` that loads normally
    /// and by a successful `save` that is not blocked.
    public private(set) var issue: WatchCaptureQueueIssue?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Distinguishes a missing queue from one that is present but damaged.
    public func read() -> WatchCaptureQueueLoad {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
            return .unreadable(reason: error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .loaded(try decoder.decode([WatchCapture].self, from: data))
        } catch {
            return .corrupt(reason: error.localizedDescription)
        }
    }

    /// The captures a queue should start with. A corrupt file is moved aside
    /// with its bytes intact and the queue starts empty; an unreadable file,
    /// or a corrupt one that cannot be moved, is left alone and blocks saving.
    public func open() -> [WatchCapture] {
        switch read() {
        case .absent:
            issue = nil
            return []
        case .loaded(let captures):
            issue = nil
            return captures
        case .unreadable:
            issue = .unreadable
            return []
        case .corrupt:
            do {
                issue = .setAside(try quarantine())
            } catch {
                issue = .damaged
            }
            return []
        }
    }

    public func save(_ captures: [WatchCapture]) throws {
        if let issue, issue.blocksSaving { throw WatchCaptureQueueFileError.damagedQueue }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(captures)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            issue = .saveFailed
            throw error
        }
        if issue == .saveFailed { issue = nil }
    }

    /// Dismisses a notice that needs no action (a queue already set aside).
    public func dismissNotice() {
        if case .setAside = issue { issue = nil }
    }

    /// Keeps the damaged bytes beside the queue under a new name. Never
    /// deletes them and never replaces an existing file.
    private func quarantine() throws -> URL {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let destination = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(UUID().uuidString)")
            .appendingPathExtension(fileURL.pathExtension)
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }
}
