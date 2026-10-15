import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

private final class NativeHostScript: @unchecked Sendable {
    let condition = NSCondition()
    var released = false
    var retireFailures = 0
    var lateFailure = false
    var retireCalls = 0
    var onQuiesce: @Sendable () -> Void = {}
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
    func flushGate() {
        onQuiesce()
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }
    func retirementCount() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return retireCalls
    }
}

private struct NativeHostFactory: DesktopOwnedCaptureDriverFactory {
    let script: NativeHostScript
    func makeDriver() -> NativeHostDriver { NativeHostDriver(script: script) }
}

private final class NativeHostDriver: DesktopOwnedCaptureDriver {
    struct Failure: Error {}
    let script: NativeHostScript
    var bridge: DesktopOwnedCaptureCallbackBridge?
    init(script: NativeHostScript) { self.script = script }
    func open(bridge: DesktopOwnedCaptureCallbackBridge) { self.bridge = bridge }
    func quiesce() -> DesktopOwnedCaptureReceipt {
        script.flushGate()
        let tail = Array(Int16(1)...Int16(73))
        tail.withUnsafeBufferPointer { bridge?.receivePCM($0.baseAddress, count: $0.count) }
        return .init(producerQuiesced: true, callbacksDrained: true, resourcesRetired: false)
    }
    func retire() throws -> DesktopOwnedCaptureReceipt {
        script.condition.lock()
        script.retireCalls += 1
        let failed = script.retireFailures > 0
        if failed { script.retireFailures -= 1 }
        script.condition.unlock()
        if script.lateFailure { bridge?.fail("synthetic native after fence") }
        if failed { throw Failure() }
        return .init(
            producerQuiesced: true, callbacksDrained: true, resourcesRetired: true,
            audioFailure: script.lateFailure ? "synthetic native after fence" : nil
        )
    }
}

private actor NativeHostSteps {
    var finishes = 0
    func observe(_ step: DesktopHostOwnedFileStep) { if case .finish = step { finishes += 1 } }
}

@MainActor
private final class NativeHostFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-owned-\(UUID())")
    let script = NativeHostScript()
    let steps = NativeHostSteps()
    let worker: DesktopOwnedCaptureWorker<NativeHostFactory>
    var host: DesktopHostController<FakePlatform>?
    var owner: DesktopHostOwnedStartup?
    init() { self.worker = DesktopOwnedCaptureWorker(factory: NativeHostFactory(script: script)) }

    func prepare() async throws {
        let host = try DesktopHostController(
            directory: directory, effects: SyntheticEffects(), shutdownGrace: .milliseconds(20)
        )
        self.host = host
        await host.markReadyForSelfTest()
        var dependency = DesktopHostOwnedStartupDependency(worker: worker)
        dependency.beforeFile = { [steps] in await steps.observe($0) }
        let owner = try await host.admitOwnedCaptureStartup(
            identity: .init(
                deviceID: "synthetic", routeID: "fixture", profileID: "", sampleRate: 24000, frameMilliseconds: 100
            ),
            admission: .init(enabled: true, capability: .qualified, permission: .granted, owner: .idle),
            limits: DesktopPressCaptureBufferLimits(preRollFrames: 2400, reservedFrames: 4800),
            dependency: dependency
        )
        self.owner = owner
        try await phase(.prepared)
        try await host.requestOwnedRecording(requestID: owner.id)
        try await phase(.recording)
    }
    func phase(_ phase: DesktopHostOwnedStartupSnapshot.Phase) async throws {
        let owner = try XCTUnwrap(owner)
        for _ in 0..<1500 {
            if await owner.snapshot().phase == phase { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Missing native Host phase \(phase)")
        throw DesktopHostError(message: "Native Host phase timed out.")
    }
    func cleanup() async throws {
        script.release()
        await owner?.abort()
        await host?.close()
        if let owner {
            while true {
                let state = await owner.snapshot()
                if state.phase == .finished { _ = await owner.waitForRecordingOutcome(); break }
                if state.phase == .cleanupFailed {
                    guard state.cleanupFailure == .cleanupFailed("Failure()") else {
                        throw DesktopHostError(message: "Unexpected fixture retirement failure: \(state)")
                    }
                    try await owner.retryRelease()
                } else if state.phase == .dispositionFailed {
                    throw DesktopHostError(message: "Unexpected fixture disposition failure.")
                } else { await Task.yield() }
            }
        }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

@MainActor
final class DesktopHostNativeOwnedCaptureTests: XCTestCase {
    func testRealWorkerKeepsWAVOpenUntilFinal73SamplesAndRetirement() async throws {
        let fixture = NativeHostFixture()
        addTeardownBlock { try await fixture.cleanup() }
        let quiescing = expectation(description: "native quiescence")
        fixture.script.onQuiesce = { quiescing.fulfill() }
        try await fixture.prepare()
        let host = try XCTUnwrap(fixture.host)
        let owner = try XCTUnwrap(fixture.owner)
        try await host.requestOwnedRecordingStop(requestID: owner.id)
        await fulfillment(of: [quiescing], timeout: 3)
        let before = await fixture.steps.finishes
        XCTAssertEqual(before, 0)
        fixture.script.release()
        let outcome = await owner.waitForRecordingOutcome()
        let record = try await host.store.record(id: outcome.recordID)
        let url = try await host.store.audioURL(for: record)
        let bytes = try Data(contentsOf: url)
        let expected = Array(Int16(1)...Int16(73)).withUnsafeBytes { Data($0) }
        XCTAssertEqual(Data(bytes.dropFirst(44)), expected)
        XCTAssertEqual(record.recordedDuration, 73.0 / 24000)
        XCTAssertNil(record.result)
        XCTAssertTrue(record.failure?.contains("No dictation") == true)
        XCTAssertTrue(outcome.causes.isEmpty)
    }

    func testPostFenceNativeFailureAndRetainedRetirementRetryStayCaptureOnly() async throws {
        let fixture = NativeHostFixture()
        addTeardownBlock { try await fixture.cleanup() }
        fixture.script.lateFailure = true
        fixture.script.retireFailures = 1
        fixture.script.release()
        try await fixture.prepare()
        let host = try XCTUnwrap(fixture.host)
        let owner = try XCTUnwrap(fixture.owner)
        try await host.requestOwnedRecordingStop(requestID: owner.id)
        try await fixture.phase(.cleanupFailed)
        let before = await fixture.steps.finishes
        XCTAssertEqual(before, 0)
        let failed = await owner.snapshot()
        XCTAssertEqual(failed.cleanupFailure, .cleanupFailed("Failure()"))
        XCTAssertEqual(fixture.script.retirementCount(), 1)
        try await owner.retryRelease()
        try await assertFailedCapture(
            fixture, causes: [.captureFailed("synthetic native after fence"), .cleanupFailed("Failure()")],
            retirements: 2
        )
    }

    func testPostFenceNativeFailureWithoutRetirementFailurePreservesRecoveryWAV() async throws {
        let fixture = NativeHostFixture()
        addTeardownBlock { try await fixture.cleanup() }
        fixture.script.lateFailure = true
        let quiescing = expectation(description: "native quiescence")
        fixture.script.onQuiesce = { quiescing.fulfill() }
        try await fixture.prepare()
        let host = try XCTUnwrap(fixture.host)
        let owner = try XCTUnwrap(fixture.owner)
        try await host.requestOwnedRecordingStop(requestID: owner.id)
        await fulfillment(of: [quiescing], timeout: 3)
        let before = await fixture.steps.finishes
        XCTAssertEqual(before, 0)
        XCTAssertEqual(fixture.script.retirementCount(), 0)
        fixture.script.release()
        try await assertFailedCapture(
            fixture, causes: [.captureFailed("synthetic native after fence")], retirements: 1
        )
    }

    private func assertFailedCapture(
        _ fixture: NativeHostFixture, causes: [DesktopPressCaptureError], retirements: Int
    ) async throws {
        let host = try XCTUnwrap(fixture.host)
        let owner = try XCTUnwrap(fixture.owner)
        let outcome = await owner.waitForRecordingOutcome()
        XCTAssertEqual(outcome.causes, causes)
        let state = await owner.snapshot()
        XCTAssertEqual(state.phase, .finished)
        XCTAssertNil(state.cleanupFailure)
        XCTAssertNil(state.audioFailure)
        XCTAssertNil(state.historyFailure)
        XCTAssertNil(state.persistenceFailure)
        XCTAssertNil(state.contractFailure)
        XCTAssertEqual(fixture.script.retirementCount(), retirements)
        let finishes = await fixture.steps.finishes
        XCTAssertEqual(finishes, 1)
        let record = try await host.store.record(id: outcome.recordID)
        XCTAssertNil(record.result)
        for cause in causes {
            XCTAssertTrue(record.failure?.contains(String(describing: cause)) == true)
        }
        XCTAssertNil(record.recordedDuration)
        let url = try await host.store.audioURL(for: record)
        let bytes = try Data(contentsOf: url)
        let wave = try XCTUnwrap(bytes.count == 190 ? bytes : nil)
        XCTAssertEqual(Data(wave[0..<4]), Data("RIFF".utf8))
        XCTAssertEqual(littleEndianUInt32(wave, at: 4), 182)
        XCTAssertEqual(Data(wave[8..<16]), Data("WAVEfmt ".utf8))
        XCTAssertEqual(littleEndianUInt32(wave, at: 16), 16)
        XCTAssertEqual(Array(wave[20..<24]), [1, 0, 1, 0])
        XCTAssertEqual(littleEndianUInt32(wave, at: 24), 24000)
        XCTAssertEqual(littleEndianUInt32(wave, at: 28), 48000)
        XCTAssertEqual(Array(wave[32..<36]), [2, 0, 16, 0])
        XCTAssertEqual(Data(wave[36..<40]), Data("data".utf8))
        XCTAssertEqual(littleEndianUInt32(wave, at: 40), 146)
        let expected = (1...73).flatMap { [UInt8($0), UInt8(0)] }
        XCTAssertEqual(Data(wave[44...]), Data(expected))
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
}
