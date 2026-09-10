#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

/// Startup-boundary observations reported by the real iOS orchestration
/// (issue #972).
///
/// The pure recorder is proven on the host in `StartupDiagnosticsTests`; these
/// tests run the actual transcribers and the actual session seam on an iOS
/// destination, with the audio-session boundary made controllable, so the
/// wiring is exercised rather than assumed.
@MainActor
final class StartupDiagnosticsObservationTests: XCTestCase {
    private struct Backend {
        let start: @MainActor () async throws -> Void
        let cancel: @MainActor () -> Void
        var setObserver: @MainActor (@escaping (StartupObservation) -> Void) -> Void
    }

    private final class TaskBox {
        var task: Task<Void, Error>?
    }

    private enum StubError: Error { case configurationRefused }

    private static let kinds = ["apple", "openai", "shared", "batch"]

    /// The audio-session boundary is real: the stage is reported only once
    /// `configureForRecording()` has actually returned.
    func testEveryBackendReportsTheAudioSessionBoundaryItActuallyCrossed() async throws {
        for kind in Self.kinds {
            let manager = AudioSessionManager()
            manager.permissionStatus = { true }
            manager.configureRecording = {}
            manager.deactivateRecording = {}

            var observed: [StartupObservation] = []
            let box = TaskBox()
            let backend = try makeBackend(kind, manager: manager)
            backend.setObserver { observation in
                observed.append(observation)
                // Stop the run at the boundary under test, so nothing beyond
                // it can be attributed to this measurement.
                if case .stage(.audioSessionConfigured) = observation { box.task?.cancel() }
            }

            box.task = Task { @MainActor in try await backend.start() }
            do {
                try await box.task?.value
            } catch {
                // A cancelled start is the expected outcome here.
            }
            backend.cancel()

            XCTAssertTrue(
                observed.contains(.stage(.audioSessionConfigured)),
                "\(kind) did not report the audio-session boundary"
            )
            XCTAssertFalse(
                observed.contains(.stage(.engineStarted)),
                "\(kind) reported an engine start it never reached"
            )
        }
    }

    /// A start that fails before a boundary must leave that boundary absent —
    /// never zero, never a fabricated success.
    func testEveryBackendOmitsBoundariesItNeverReached() async throws {
        for kind in Self.kinds {
            let manager = AudioSessionManager()
            manager.permissionStatus = { true }
            manager.configureRecording = { throw StubError.configurationRefused }
            manager.deactivateRecording = {}

            var observed: [StartupObservation] = []
            let backend = try makeBackend(kind, manager: manager)
            backend.setObserver { observed.append($0) }

            do {
                try await backend.start()
                XCTFail("\(kind) started despite a refused audio session")
            } catch {
                // Expected.
            }
            backend.cancel()

            XCTAssertFalse(observed.contains(.stage(.audioSessionConfigured)), kind)
            XCTAssertFalse(observed.contains(.stage(.engineStarted)), kind)
        }
    }

    /// The observations reach the caller through the existing session
    /// boundary, not through a second mechanism of their own.
    func testSessionForwardsObservationsThroughItsExistingBoundary() async throws {
        let manager = AudioSessionManager()
        manager.permissionStatus = { true }
        manager.configureRecording = {}
        manager.deactivateRecording = {}

        let session = try IOSTranscriptionSession(
            modelID: "openai/gpt-4o-mini-transcribe",
            mode: .batch(retainRecording: false),
            audioSessionManager: manager,
            batchAPIKey: "test-key",
            liveAPIKey: { _ in "test-key" }
        )
        var observed: [StartupObservation] = []
        let box = TaskBox()
        session.onStartupObservation = { observation in
            observed.append(observation)
            if case .stage(.audioSessionConfigured) = observation { box.task?.cancel() }
        }

        box.task = Task { @MainActor in try await session.start() }
        do {
            try await box.task?.value
        } catch {
            // A cancelled start is the expected outcome here.
        }
        session.cancel()

        XCTAssertTrue(observed.contains(.stage(.audioSessionConfigured)))
        XCTAssertFalse(observed.contains(.stage(.engineStarted)))
    }

    /// Routing settles batch, OpenAI and shared-client starts outright; only
    /// the Apple path still has a branch to take, so it labels itself later
    /// rather than being guessed here.
    func testOnlySettledBackendsAreLabelledFromRouting() throws {
        for route in LiveTranscriptionRouting.allRoutes where route.provider.isSupportedOnIOS {
            let resolution = try IOSTranscriptionSession.resolve(modelID: route.modelID, mode: .streaming)
            switch resolution.backend {
            case .apple:
                XCTAssertNil(resolution.resolvedStartupBackend, route.modelID)
            case .openAI:
                XCTAssertEqual(resolution.resolvedStartupBackend, .openAIRealtime, route.modelID)
            case .shared:
                XCTAssertEqual(resolution.resolvedStartupBackend, .sharedClient, route.modelID)
            case .batch:
                XCTFail("streaming route resolved to batch: \(route.modelID)")
            }
        }
        let batch = try IOSTranscriptionSession.resolve(
            modelID: "openai/gpt-4o-mini-transcribe",
            mode: .batch(retainRecording: false)
        )
        XCTAssertEqual(batch.resolvedStartupBackend, .batch)
    }

    // MARK: - Backends

    private func makeBackend(_ kind: String, manager: AudioSessionManager) throws -> Backend {
        switch kind {
        case "apple":
            let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
            transcriber.permissionCheck = { true }
            return Backend(
                start: { try await transcriber.start() },
                cancel: transcriber.cancel,
                setObserver: { observer in transcriber.onStartupObservation = observer }
            )
        case "openai":
            let transcriber = OpenAIRealtimeLiveTranscriber(audioSessionManager: manager)
            transcriber.configure(apiKey: "test-key")
            return Backend(
                start: transcriber.start,
                cancel: transcriber.cancel,
                setObserver: { observer in transcriber.onStartupObservation = observer }
            )
        case "shared":
            let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "deepgram/nova-3-streaming"))
            let transcriber = SharedClientLiveTranscriber(
                route: route, apiKey: "test-key", audioSessionManager: manager
            )
            return Backend(
                start: transcriber.start,
                cancel: transcriber.cancel,
                setObserver: { observer in transcriber.onStartupObservation = observer }
            )
        default:
            let transcriber = IOSBatchTranscriber(
                audioSessionManager: manager, model: "openai/gpt-4o-mini-transcribe", apiKey: "test-key"
            )
            return Backend(
                start: transcriber.start,
                cancel: transcriber.cancel,
                setObserver: { observer in transcriber.onStartupObservation = observer }
            )
        }
    }
}
#endif
