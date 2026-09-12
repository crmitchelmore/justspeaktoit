import Foundation

/// An alternate file-producing capture boundary. The ordinary recorder remains
/// the default; sources such as prerecorded fixtures do not need a physical mic.
protocol RecordingCaptureSource: Sendable {
    func start(in directory: URL) async throws -> RecordingStart
    func stop() async throws -> RecordingSummary
    func cancel(deleteFile: Bool) async
}
