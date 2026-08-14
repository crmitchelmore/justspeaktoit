import Foundation
import Network
import XCTest

@testable import SpeakApp

@MainActor
final class CaptureWarmCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        self.suiteName = "com.speakapp.capture-warm-tests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)!
        self.defaults.set(AppSettings.TranscriptionMode.liveNative.rawValue, forKey: "transcriptionMode")
        self.defaults.set("deepgram/nova-3-streaming", forKey: "liveTranscriptionModel")
        self.defaults.set(true, forKey: "connectionPreWarmingEnabled")
        self.defaults.set(false, forKey: "audioPreWarmingEnabled")
        self.defaults.set(["deepgram.apiKey"], forKey: "trackedKeyIdentifiers")
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        super.tearDown()
    }

    func testFreshnessDeadline_ActivelySchedulesAndRunsAReplacementProbe() async {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = self.makeHarness(now: { now })
        harness.coordinator.start()
        await self.drainTasks()

        let firstProbeHosts = await harness.warmer.hosts()
        XCTAssertEqual(firstProbeHosts, ["api.deepgram.com"])
        XCTAssertEqual(harness.scheduler.delay, 90)

        now = now.addingTimeInterval(90)
        harness.scheduler.fire()
        await self.drainTasks()

        let refreshedProbeHosts = await harness.warmer.hosts()
        XCTAssertEqual(refreshedProbeHosts, ["api.deepgram.com", "api.deepgram.com"])
        await harness.coordinator.invalidate()
    }

    func testSleepAndWake_CancelThenReprobeTheEndpoint() async {
        let harness = self.makeHarness()
        harness.coordinator.start()
        await self.drainTasks()

        harness.workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await self.drainTasks()
        XCTAssertNil(harness.scheduler.delay)

        harness.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await self.drainTasks()
        let probeHosts = await harness.warmer.hosts()
        XCTAssertEqual(probeHosts.count, 2)
        await harness.coordinator.invalidate()
    }

    func testNetworkRecovery_InvalidatesAndReprobesTheEndpoint() async {
        let harness = self.makeHarness()
        harness.coordinator.start()
        await self.drainTasks()

        harness.network.send(.unsatisfied)
        await self.drainTasks()
        XCTAssertNil(harness.scheduler.delay)

        harness.network.send(.satisfied)
        await self.drainTasks()
        let probeHosts = await harness.warmer.hosts()
        XCTAssertEqual(probeHosts.count, 2)
        await harness.coordinator.invalidate()
    }

    func testTranscriptionModeChange_InvalidatesTheScheduledProbe() async {
        let harness = self.makeHarness()
        harness.coordinator.start()
        await self.drainTasks()

        harness.settings.transcriptionMode = .batchRemote
        await self.drainTasks()

        XCTAssertNil(harness.scheduler.delay)
        let probeHosts = await harness.warmer.hosts()
        XCTAssertEqual(probeHosts.count, 1)
        await harness.coordinator.invalidate()
    }

    func testMicrophoneDenied_DoesNotProbeTheNetwork() async {
        let harness = self.makeHarness(microphoneStatus: .denied)
        harness.coordinator.start()
        await self.drainTasks()

        let probeHosts = await harness.warmer.hosts()
        XCTAssertTrue(probeHosts.isEmpty)
        XCTAssertNil(harness.scheduler.delay)
        await harness.coordinator.invalidate()
    }

    func testShutdown_AwaitsAudioInvalidationAndCancelsOwnedResources() async {
        let harness = self.makeHarness()
        harness.coordinator.start()
        await self.drainTasks()

        await harness.coordinator.invalidate()

        XCTAssertEqual(harness.audioInvalidation.count, 1)
        XCTAssertTrue(harness.network.wasCancelled)
        XCTAssertNil(harness.scheduler.delay)
    }

    private func makeHarness(
        microphoneStatus: PermissionStatus = .granted,
        now: @escaping @MainActor () -> Date = Date.init
    ) -> Harness {
        let settings = AppSettings(defaults: self.defaults)
        let permissions = PermissionsManager(
            statusProvider: { type in type == .microphone ? microphoneStatus : .denied },
            notificationCenter: NotificationCenter()
        )
        let audioDevices = AudioInputDeviceManager(appSettings: settings)
        let audioFiles = AudioFileManager(
            appSettings: settings,
            permissionsManager: permissions,
            audioDeviceManager: audioDevices
        )
        let warmer = EndpointWarmerSpy()
        let scheduler = CaptureWarmSchedulerSpy()
        let network = CaptureWarmNetworkMonitorSpy()
        let audioInvalidation = AudioInvalidationSpy()
        let workspaceCenter = NotificationCenter()
        let coordinator = CaptureWarmCoordinator(
            appSettings: settings,
            permissionsManager: permissions,
            audioInputDeviceManager: audioDevices,
            audioFileManager: audioFiles,
            endpointWarmer: warmer,
            networkMonitor: network,
            scheduler: scheduler,
            workspaceNotificationCenter: workspaceCenter,
            notificationCenter: NotificationCenter(),
            now: now,
            warmAudio: { _, _ in },
            invalidateAudio: { audioInvalidation.record() }
        )
        return Harness(
            coordinator: coordinator,
            settings: settings,
            warmer: warmer,
            scheduler: scheduler,
            network: network,
            audioInvalidation: audioInvalidation,
            workspaceCenter: workspaceCenter
        )
    }

    private func drainTasks() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private struct Harness {
    let coordinator: CaptureWarmCoordinator
    let settings: AppSettings
    let warmer: EndpointWarmerSpy
    let scheduler: CaptureWarmSchedulerSpy
    let network: CaptureWarmNetworkMonitorSpy
    let audioInvalidation: AudioInvalidationSpy
    let workspaceCenter: NotificationCenter
}

private actor EndpointWarmCalls {
    private var storedHosts: [String] = []

    func append(_ host: String) {
        self.storedHosts.append(host)
    }

    func hosts() -> [String] {
        self.storedHosts
    }
}

private final class EndpointWarmerSpy: StreamingEndpointWarming, @unchecked Sendable {
    private let calls = EndpointWarmCalls()

    func hosts() async -> [String] {
        await self.calls.hosts()
    }

    func warmUp(host: String) async -> Bool {
        await self.calls.append(host)
        return true
    }
}

@MainActor
private final class CaptureWarmSchedulerSpy: CaptureWarmScheduling {
    private(set) var delay: TimeInterval?
    private var operation: (@MainActor @Sendable () -> Void)?

    func schedule(after delay: TimeInterval, operation: @escaping @MainActor @Sendable () -> Void) {
        self.delay = delay
        self.operation = operation
    }

    func cancel() {
        self.delay = nil
        self.operation = nil
    }

    func fire() {
        let operation = self.operation
        self.cancel()
        operation?()
    }
}

@MainActor
private final class CaptureWarmNetworkMonitorSpy: CaptureWarmNetworkMonitoring {
    var statusDidChange: ((NWPath.Status) -> Void)?
    private(set) var wasCancelled = false

    func start() {}

    func cancel() {
        self.wasCancelled = true
        self.statusDidChange = nil
    }

    func send(_ status: NWPath.Status) {
        self.statusDidChange?(status)
    }
}

@MainActor
private final class AudioInvalidationSpy {
    private(set) var count = 0

    func record() {
        self.count += 1
    }
}
