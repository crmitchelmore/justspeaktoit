#if os(macOS)
import Foundation
import XCTest

final class WatchRecordingEntryPointTests: XCTestCase {
    /// Compile the real watch coordinator and capture store with device doubles. This
    /// exercises headless entry on the host without adding production injection
    /// seams or claiming to exercise WatchConnectivity on paired hardware.
    func testHeadlessRecording_delayedActivationRecoversRetainedAudio() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = directory.appendingPathComponent("HeadlessEntry.swift")
        try Self.harness.write(to: harness, atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("headless-entry")
        let connectivity = directory.appendingPathComponent("WatchConnectivity.swift")
        try Self.connectivityDouble.write(to: connectivity, atomically: true, encoding: .utf8)
        let module = try self.run("/usr/bin/xcrun", arguments: [
            "swiftc", "-j", "4", "-emit-library", "-emit-module", "-module-name", "WatchConnectivity",
            "-emit-module-path", directory.appendingPathComponent("WatchConnectivity.swiftmodule").path,
            connectivity.path, "-o", directory.appendingPathComponent("libWatchConnectivity.dylib").path
        ])
        XCTAssertEqual(module.status, 0, module.output)
        guard module.status == 0 else { return }

        let compiler = try self.run("/usr/bin/xcrun", arguments: [
            "swiftc", "-parse-as-library", "-j", "4",
            "-I", directory.path, "-L", directory.path, "-lWatchConnectivity",
            "-Xlinker", "-rpath", "-Xlinker", directory.path,
            root.appendingPathComponent("JustSpeakWatch/WatchRecordingCoordinator.swift").path,
            root.appendingPathComponent("JustSpeakWatch/WatchCaptureStore.swift").path,
            root.appendingPathComponent("Sources/SpeakCore/WatchCaptureProtocol.swift").path,
            root.appendingPathComponent("Sources/SpeakCore/WatchRecordingToggleSerialiser.swift").path,
            harness.path, "-o", executable.path
        ])
        XCTAssertEqual(compiler.status, 0, compiler.output)
        guard compiler.status == 0 else { return }
        let result = try self.run(executable.path, arguments: [directory.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "headless entry passed")
    }

    private func run(_ executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // A file avoids blocking on pipe EOF if a stalled compiler child keeps
        // an inherited output descriptor open after its parent is terminated.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: log)
        }
        process.standardOutput = output
        process.standardError = output
        let finished = XCTestExpectation(description: "Subprocess exited: \(executable)")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        guard XCTWaiter.wait(for: [finished], timeout: 60) == .completed else {
            if process.isRunning { process.terminate() }
            return (-1, "Subprocess exceeded its 60-second deadline: \(executable)")
        }
        return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
    }

    private static let connectivityDouble = """
    import Foundation
    @_exported import Combine

    public enum WCSessionActivationState { case notActivated, activated }
    public protocol WCSessionDelegate: AnyObject {
        func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?)
    }
    public final class WCSessionFile {
        public var metadata: [String: Any]?
        init(metadata: [String: Any]?) { self.metadata = metadata }
    }
    public final class WCSessionFileTransfer {
        public let file: WCSessionFile
        init(metadata: [String: Any]?) { file = WCSessionFile(metadata: metadata) }
    }
    public final class WCSession {
        public static let `default` = WCSession()
        public static func isSupported() -> Bool { true }
        public weak var delegate: WCSessionDelegate?
        public var activationState = WCSessionActivationState.notActivated
        public var isReachable = false
        public var activationCalls = 0
        public var outstandingFileTransfers: [WCSessionFileTransfer] = []
        // Deliberately withhold completion until after the recording is queued.
        public func activate() { activationCalls += 1 }
        public func completeActivation() {
            activationState = .activated
            delegate?.session(self, activationDidCompleteWith: .activated, error: nil)
        }
        public func transferFile(_ url: URL, metadata: [String: Any]?) {
            precondition(activationState == .activated)
            outstandingFileTransfers.append(WCSessionFileTransfer(metadata: metadata))
        }
    }
    """

    private static let harness = """
    import Foundation
    import WatchConnectivity

    struct WatchSharedContainer {
        static let shared = WatchSharedContainer()
        func migrateLegacyFile(named: String) {}
        func url(named: String) -> URL {
            URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(named)
        }
    }
    @MainActor
    final class WatchComplicationPublisher {
        static let shared = WatchComplicationPublisher()
        func update(captures: [WatchCapture]) {}
    }
    @MainActor
    final class WatchAudioRecorder {
        struct FinishedRecording {
            let id: UUID
            let createdAt = Date()
            let duration: TimeInterval = 2
        }
        let id = UUID()
        var toggleCount = 0
        static func fileURL(for id: UUID) -> URL {
            WatchSharedContainer.shared.url(named: id.uuidString + ".m4a")
        }
        func toggle() async {
            precondition(WCSession.default.activationCalls == 1, "Recording entered before activation was requested")
            precondition(WCSession.default.activationState == .notActivated)
            toggleCount += 1
            if toggleCount == 1 {
                try! Data("recorded audio".utf8).write(to: Self.fileURL(for: id))
            } else {
                precondition(WatchCaptureStore.shared.enqueue(FinishedRecording(id: id)))
            }
        }
    }
    enum WatchRecordingRequest {
        static func claim() -> UUID? { nil }
        static func consume(_ claim: UUID) -> UUID? { claim }
    }
    @main
    struct HeadlessEntry {
        @MainActor
        static func main() async {
            // Bound a regression that waits for activation instead of recording.
            Task.detached {
                try? await Task.sleep(for: .seconds(10))
                exit(2)
            }
            let coordinator = WatchRecordingCoordinator.shared
            let store = WatchCaptureStore.shared
            let session = WCSession.default
            // No scene. Start and stop while activation is still pending and the
            // phone is unreachable. The actual store must durably retain audio.
            await coordinator.toggleRecording()
            await coordinator.toggleRecording()
            precondition(coordinator.recorder.toggleCount == 2)
            precondition(session.activationCalls == 1)
            precondition(store.captures.count == 1 && store.captures[0].status == .recorded)
            precondition(session.outstandingFileTransfers.isEmpty)
            let audio = WatchAudioRecorder.fileURL(for: coordinator.recorder.id)
            precondition(FileManager.default.fileExists(atPath: audio.path))
            let queue = WatchSharedContainer.shared.url(named: "captures.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = try! decoder.decode([WatchCapture].self, from: Data(contentsOf: queue))
            precondition(persisted.count == 1 && persisted[0].id == store.captures[0].id)
            precondition(persisted[0].status == .recorded)

            session.completeActivation()
            while store.captures[0].status != .transferring { await Task.yield() }
            precondition(!session.isReachable)
            precondition(session.outstandingFileTransfers.count == 1)
            // Later scene activation/recovery must not duplicate the transfer.
            store.activate()
            store.retryPending()
            precondition(session.activationCalls == 1)
            precondition(session.outstandingFileTransfers.count == 1)
            precondition(FileManager.default.fileExists(atPath: audio.path))
            print("headless entry passed")
        }
    }
    """
}
#endif
