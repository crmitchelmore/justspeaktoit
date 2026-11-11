import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class SessionStartPipelineTests: XCTestCase {
    private final class FakeHost: SessionStartHost {
        var activeSession: ActiveSession?
        var mayStartSession = true
        var isStreamingTranscriptionMode = false
        var activated: [ActiveSession] = []
        var captureStarts: [ActiveSession] = []
        var rejections: [String] = []
        var failures: [String] = []
        let diagnostics: () -> HistoryDiagnosticContext

        init(diagnostics: @escaping () -> HistoryDiagnosticContext) {
            self.diagnostics = diagnostics
        }

        func activate(_ session: ActiveSession) {
            activeSession = session
            activated.append(session)
        }

        func captureDidStart(for session: ActiveSession) { captureStarts.append(session) }
        func publishStartRejection(_ message: String) { rejections.append(message) }
        func publishMissingLiveAPIKey(_ alert: MissingLiveAPIKeyAlert) {}
        func makeAdmissionDiagnosticContext() -> HistoryDiagnosticContext { diagnostics() }
        func sessionProcessingShouldContinue(_ session: ActiveSession) -> Bool { activeSession === session }

        func failStartedSession(message: String) {
            failures.append(message)
            activeSession = nil
        }
    }

    private struct Harness {
        let pipeline: SessionStartPipeline
        let host: FakeHost
        let runtime: SessionCaptureRuntime
        let ownership: CaptureSessionOwnership
        let audio: AudioFileManager
        let abandonedStarts: () -> Int
        let cues: () -> Int
    }

    private var environment: AppEnvironment!
    private var recordingsDirectory: URL!

    override func setUp() async throws {
        environment = WireUp.bootstrap(options: makeWireUpTestOptions())
        recordingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStartPipelineTests-\(UUID().uuidString)", isDirectory: true)
        environment.settings.recordingsDirectory = recordingsDirectory
        environment.settings.transcriptionMode = .batchRemote
    }

    override func tearDown() async throws {
        if let recordingsDirectory {
            try? FileManager.default.removeItem(at: recordingsDirectory)
        }
        environment = nil
    }

    private func makeRuntime(onCue: @escaping () -> Void) -> SessionCaptureRuntime {
        SessionCaptureRuntime(
            context: SessionCaptureRuntime.Context(
                meterReading: { nil },
                silenceSettings: { .off },
                isRecording: { true },
                silenceStopEligible: { false },
                updateAudioLevel: { _ in },
                markAudioLive: {},
                playCue: { _ in onCue() },
                silenceElapsed: {}
            ),
            hudOcclusion: HUDOcclusionObserver(notificationCenter: NotificationCenter(), isAppVisible: { true }),
            schedulesTimer: false
        )
    }

    private func makeHarness(source: any RecordingCaptureSource) -> Harness {
        let env = environment!
        let audio = AudioFileManager(
            appSettings: env.settings,
            permissionsManager: env.permissions,
            audioDeviceManager: env.audioDevices,
            captureSource: source
        )
        var cueCount = 0
        let runtime = makeRuntime { cueCount += 1 }
        var abandoned = 0
        let retirement = SessionRetirement(
            steps: SessionRetirement.Steps(
                finishAutomationCapture: { _ in },
                restoreProfile: { abandoned += 1 },
                resumeCaptureWarming: {},
                releaseDictationCapture: {},
                resumeKeyPressPriming: {}
            )
        )
        let ownership = CaptureSessionOwnership()
        let main = env.main
        let pipeline = SessionStartPipeline(
            settings: env.settings,
            capture: SessionCaptureServices(
                permissions: env.permissions, devices: env.audioDevices, hotKeys: env.hotKeys, audioFiles: audio,
                profiles: env.profiles
            ),
            transcription: env.transcription,
            postProcessing: env.postProcessing,
            hud: env.hud,
            owners: SessionStartPipeline.Owners(
                captureRuntime: runtime,
                captureHealth: main.captureHealth,
                keyPressPrimer: main.keyPressPrimer,
                captureWarmer: main.captureWarmer,
                captureOwnership: ownership,
                retirement: retirement,
                profileApplier: SessionProfileApplier(),
                soundPlayer: RecordingSoundPlayer()
            )
        )
        let host = FakeHost { main.makeHistoryDiagnosticContext(includeRequestedContext: true) }
        pipeline.host = host
        return Harness(
            pipeline: pipeline, host: host, runtime: runtime, ownership: ownership, audio: audio,
            abandonedStarts: { abandoned }, cues: { cueCount }
        )
    }

    func testStart_refusedWhileTheHostCannotStart() async {
        let harness = makeHarness(source: FailingSource())
        harness.host.mayStartSession = false

        let outcome = await harness.pipeline.start(.init(trigger: .uiButton))

        XCTAssertEqual(outcome, .rejected(.captureFailed))
        XCTAssertTrue(harness.host.activated.isEmpty)
        XCTAssertEqual(harness.abandonedStarts(), 0, "Nothing was taken, so nothing is undone")
    }

    func testStart_handsFreeOnAnUnsupportedRouteIsRejectedBeforeASessionExists() async {
        let harness = makeHarness(source: FailingSource())

        let outcome = await harness.pipeline.start(.init(trigger: .handsFree))

        XCTAssertEqual(outcome, .rejected(.unsupportedConfiguration))
        XCTAssertTrue(harness.host.activated.isEmpty)
        XCTAssertEqual(harness.abandonedStarts(), 1, "The profile and warm hand-off are undone")
        XCTAssertNil(harness.ownership.owner)
        XCTAssertFalse(harness.pipeline.isStarting)
    }

    func testStart_refusedWhileVoiceEditOwnsCapture() async {
        let harness = makeHarness(source: FailingSource())
        harness.ownership.reserve(.voiceEdit)

        let outcome = await harness.pipeline.start(.init(trigger: .uiButton))

        XCTAssertEqual(outcome, .rejected(.captureFailed))
        XCTAssertEqual(harness.host.rejections, ["Voice edit is in progress. Finish or cancel it first."])
        XCTAssertTrue(harness.host.activated.isEmpty)
        XCTAssertEqual(harness.ownership.owner, .voiceEdit, "Voice Edit keeps its reservation")
    }

    func testStart_bringsCaptureUpAndArmsTheRuntime() async {
        let harness = makeHarness(source: CoreJourneyRecordingSource())

        let outcome = await harness.pipeline.start(.init(trigger: .uiButton))

        XCTAssertEqual(outcome, .started)
        let session = try? XCTUnwrap(harness.host.activated.first)
        XCTAssertEqual(harness.host.captureStarts.map(ObjectIdentifier.init), session.map { [ObjectIdentifier($0)] })
        XCTAssertNotNil(session?.captureStarted)
        XCTAssertNotNil(session?.diagnosticContext)
        XCTAssertEqual(harness.ownership.owner, .dictation)
        XCTAssertTrue(harness.runtime.isMonitoring)
        XCTAssertEqual(harness.cues(), 0, "The cue waits for the first audio")

        harness.runtime.tick(now: Date().addingTimeInterval(2))
        XCTAssertEqual(harness.cues(), 1, "An unmetered input counts as arrival")

        await harness.audio.cancelRecording(deleteFile: true)
    }

    func testStart_captureFailureIsReportedThroughTheHost() async {
        let harness = makeHarness(source: FailingSource())

        let outcome = await harness.pipeline.start(.init(trigger: .uiButton))

        XCTAssertEqual(outcome, .rejected(.captureFailed))
        XCTAssertEqual(harness.host.failures, ["capture refused"])
        let session = harness.host.activated.first
        XCTAssertEqual(session?.errors.map(\.message), ["Failed to start recording"])
        XCTAssertTrue(harness.host.captureStarts.isEmpty)
        XCTAssertFalse(harness.runtime.isMonitoring)
    }
}

private struct CaptureRefused: LocalizedError {
    var errorDescription: String? { "capture refused" }
}

private struct FailingSource: RecordingCaptureSource {
    func start(in directory: URL) async throws -> RecordingStart { throw CaptureRefused() }
    func stop() async throws -> RecordingSummary { throw CaptureRefused() }
    func cancel(deleteFile: Bool) async {}
}
