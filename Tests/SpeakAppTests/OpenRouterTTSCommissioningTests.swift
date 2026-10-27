import Foundation
import SpeakTestSupport
import XCTest

@testable import SpeakApp
@testable import SpeakCore

@MainActor
final class OpenRouterTTSCommissioningTests: XCTestCase {
    func testExactOptInPublishesAndExportsOnceWithoutFileAutoplay() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        let output = try fixture.result(name: "completed")
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: fixture.selection.id))
        var calls = 0
        var saved: [URL] = []
        fixture.settings.ttsSaveToDirectory = true
        let manager = fixture.manager(
            option: option, save: { saved.append($0.audioURL) }, operation: { text, voice, settings, _, _ in
            calls += 1
            XCTAssertEqual(text, "Hello")
            XCTAssertEqual(voice, fixture.selection.id)
            XCTAssertEqual(settings.speed, 1)
            return TTSSynthesisOutput(result: output, playbackCompleted: true)
        })
        defer { manager.stop() }
        let result = try await bounded { try await manager.synthesize(text: "Hello") }.get()
        XCTAssertEqual(result.audioURL, output.audioURL)
        XCTAssertEqual(result.timestamp, output.timestamp)
        XCTAssertNil(result.cost)
        XCTAssertEqual(manager.lastResult?.audioURL, output.audioURL)
        XCTAssertEqual(manager.usageHistory.count, 1)
        XCTAssertEqual(saved, [output.audioURL])
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty, "This test injects only the manager operation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.audioURL.path))
        XCTAssertFalse(manager.isPlaying, "Invalid test MP3 must not be replayed after acknowledged completion")
    }

    func testGateExclusionsRetainCompletedFileRoute() async throws {
        for (autoPlay, speed, sameSelection) in [(false, 1.0, true), (true, 1.5, true),
                                                  (true, Double.nan, true), (true, 1.0, false)] {
            let fixture = try OpenRouterTTSCommissioningFixture()
            defer { fixture.cleanup() }
            fixture.refuseRequest()
            fixture.settings.ttsAutoPlay = autoPlay
            fixture.settings.ttsSpeed = speed
            let selected = sameSelection ? fixture.selection : OpenRouterSpeechSelection(modelID: "vendor/other")
            let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: selected.id))
            var calls = 0
            let manager = fixture.manager(option: option) { _, _, _, _, _ in
                calls += 1
                throw CancellationError()
            }
            defer { manager.stop() }
            let outcome = try await bounded { try await manager.synthesize(text: "Hello") }
            if case .success = outcome { XCTFail("The controlled legacy HTTP400 must fail") }
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
            XCTAssertTrue(manager.usageHistory.isEmpty)
            XCTAssertFalse(manager.isPlaying)
        }
    }

    func testOldConstructorAndExplicitDisabledOptionKeepFileRoute() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        fixture.refuseRequest()
        let old = TextToSpeechManager(
            appSettings: fixture.settings, secureStorage: fixture.storage, clients: [.openrouter: fixture.client],
            defaults: fixture.defaults
        )
        defer { old.stop() }
        _ = try await bounded { try await old.synthesize(text: "Hello") }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        var calls = 0
        let disabled = fixture.manager(option: .disabled) { _, _, _, _, _ in
            calls += 1
            throw CancellationError()
        }
        defer { disabled.stop() }
        _ = try await bounded { try await disabled.synthesize(text: "Hello") }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
    }

    func testPreviewDoesNotUseTheOptedInOpenRouterOperation() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        fixture.refuseRequest()
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: fixture.selection.id))
        var calls = 0
        let manager = fixture.manager(option: option) { _, _, _, _, _ in
            calls += 1
            throw CancellationError()
        }
        defer { manager.stop() }
        await manager.previewVoice(fixture.selection.id)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertTrue(manager.usageHistory.isEmpty)
        XCTAssertNotNil(manager.lastError)
    }

    func testCancelledQueuedWorkCannotEnterTheOwnedOperation() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: fixture.selection.id))
        var calls = 0
        let manager = fixture.manager(option: option) { _, _, _, _, _ in
            calls += 1
            throw CancellationError()
        }
        defer { manager.stop() }
        let settled = expectation(description: "Precancelled manager request settles")
        var outcome: Result<TTSResult, Error>?
        let task = Task { @MainActor in
            do { outcome = .success(try await manager.synthesize(text: "Hello")) } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        task.cancel()
        await fulfillment(of: [settled], timeout: 2)
        assertCancelled(outcome)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testStopRejectsLateUnpublishedOperationArtifact() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        let output = try fixture.result(name: "stopped")
        let entered = expectation(description: "Owned operation entered")
        let gate = OpenRouterTTSOperationGate(entered: entered)
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: fixture.selection.id))
        let manager = fixture.manager(option: option) { _, _, _, _, _ in
            await gate.wait()
            return TTSSynthesisOutput(result: output, playbackCompleted: true)
        }
        defer { gate.release(); manager.stop() }
        let settled = expectation(description: "Stopped request settles")
        var outcome: Result<TTSResult, Error>?
        let task = Task { @MainActor in
            do { outcome = .success(try await manager.synthesize(text: "Hello")) } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        manager.stop()
        gate.release()
        await fulfillment(of: [settled], timeout: 2)
        assertCancelled(outcome)
        XCTAssertNil(manager.lastResult)
        XCTAssertTrue(manager.usageHistory.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.audioURL.path))
    }

    func testUncooperativeCancelledOperationCannotPublishItsReturnedFile() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        let output = try fixture.result(name: "cancelled")
        let entered = expectation(description: "Owned operation entered")
        let gate = OpenRouterTTSOperationGate(entered: entered)
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: fixture.selection.id))
        let manager = fixture.manager(option: option) { _, _, _, _, _ in
            await gate.wait()
            return TTSSynthesisOutput(result: output, playbackCompleted: true)
        }
        defer { gate.release(); manager.stop() }
        let settled = expectation(description: "Cancelled request settles")
        var outcome: Result<TTSResult, Error>?
        let task = Task { @MainActor in
            do { outcome = .success(try await manager.synthesize(text: "Hello")) } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        gate.release()
        await fulfillment(of: [settled], timeout: 2)
        assertCancelled(outcome)
        XCTAssertTrue(manager.usageHistory.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.audioURL.path))
        XCTAssertFalse(manager.isPlaying)
    }

    private func bounded(_ operation: @escaping @MainActor () async throws -> TTSResult) async throws
        -> Result<TTSResult, Error> {
        let settled = expectation(description: "Owned synthesis settles")
        var outcome: Result<TTSResult, Error>?
        let task = Task { @MainActor in
            do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [settled], timeout: 2)
        return try XCTUnwrap(outcome, "Owned operation did not settle within the expectation bound")
    }

    private func assertCancelled(
        _ outcome: Result<TTSResult, Error>?, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(let error)? = outcome else {
            return XCTFail("Expected owned cancellation outcome", file: file, line: line)
        }
        XCTAssertTrue(error is CancellationError, file: file, line: line)
    }
}

extension OpenRouterTTSCommissioningTests {
    func testReplacedHeldOperationCannotStopOrPublishOverNewerRequest() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        let old = try fixture.result(name: "old")
        let replacement = try fixture.result(name: "replacement")
        let oldEntered = expectation(description: "Old operation entered")
        let newEntered = expectation(description: "Replacement operation entered")
        let oldGate = OpenRouterTTSOperationGate(entered: oldEntered)
        let newGate = OpenRouterTTSOperationGate(entered: newEntered)
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: fixture.selection.id))
        let manager = fixture.manager(option: option) { text, _, _, _, _ in
            if text == "Old" { await oldGate.wait() } else { await newGate.wait() }
            return TTSSynthesisOutput(result: text == "Old" ? old : replacement, playbackCompleted: true)
        }
        defer { oldGate.release(); newGate.release(); manager.stop() }
        let oldSettled = expectation(description: "Old request settles")
        let newSettled = expectation(description: "Replacement request settles")
        var oldOutcome: Result<TTSResult, Error>?
        var newOutcome: Result<TTSResult, Error>?
        let oldTask = Task { @MainActor in
            do {
                oldOutcome = .success(try await manager.synthesize(text: "Old"))
            } catch { oldOutcome = .failure(error) }
            oldSettled.fulfill()
        }
        defer { oldTask.cancel() }
        await fulfillment(of: [oldEntered], timeout: 2)
        let newTask = Task { @MainActor in
            do {
                newOutcome = .success(try await manager.synthesize(text: "New"))
            } catch { newOutcome = .failure(error) }
            newSettled.fulfill()
        }
        defer { newTask.cancel() }
        await fulfillment(of: [newEntered], timeout: 2)
        oldGate.release()
        await fulfillment(of: [oldSettled], timeout: 2)
        assertCancelled(oldOutcome)
        XCTAssertTrue(manager.isPlaying, "Old cleanup cannot clear the replacement's active output state")
        XCTAssertTrue(manager.usageHistory.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.audioURL.path))
        newGate.release()
        await fulfillment(of: [newSettled], timeout: 2)
        XCTAssertEqual(try XCTUnwrap(newOutcome).get().audioURL, replacement.audioURL)
        XCTAssertEqual(manager.lastResult?.audioURL, replacement.audioURL)
        XCTAssertEqual(manager.usageHistory.count, 1)
    }

    func testCompletedFileDispositionUsesOnlyCommonPublicationAndFilePlayback() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        let output = try fixture.result(name: "same-completed-file")
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: fixture.selection.id))
        var calls = 0
        var saves = 0
        fixture.settings.ttsSaveToDirectory = true
        let manager = fixture.manager(option: option, save: { _ in saves += 1 }, operation: { _, _, _, _, _ in
            calls += 1
            return TTSSynthesisOutput(result: output, playbackCompleted: false)
        })
        defer { manager.stop() }
        // Only the manager disposition is injected here. The intentionally
        // invalid MP3 makes its existing file player fail without native audio.
        let outcome = try await bounded { try await manager.synthesize(text: "Hello") }
        guard case .failure(let error) = outcome, let ttsError = error as? TTSError,
              case .audioPlaybackFailure = ttsError else {
            return XCTFail("Completed-file disposition must reach the existing file player")
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(manager.usageHistory.count, 1)
        XCTAssertEqual(manager.lastResult?.audioURL, output.audioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.audioURL.path))
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty, "This injected manager test performs no transport")
    }

    func testStopDuringExportKeepsPublishedArtifactButPreventsLatePlayback() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        let output = try fixture.result(name: "published")
        let entered = expectation(description: "Export entered after publication")
        let gate = OpenRouterTTSOperationGate(entered: entered)
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: fixture.selection.id))
        fixture.settings.ttsSaveToDirectory = true
        let manager = fixture.manager(option: option, save: { _ in await gate.wait() }, operation: { _, _, _, _, _ in
            TTSSynthesisOutput(result: output, playbackCompleted: false)
        })
        defer { gate.release(); manager.stop() }
        let settled = expectation(description: "Stopped export settles")
        var outcome: Result<TTSResult, Error>?
        let task = Task { @MainActor in
            do { outcome = .success(try await manager.synthesize(text: "Hello")) } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        manager.stop()
        gate.release()
        await fulfillment(of: [settled], timeout: 2)
        assertCancelled(outcome)
        XCTAssertEqual(manager.lastResult?.audioURL, output.audioURL)
        XCTAssertEqual(manager.usageHistory.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.audioURL.path))
        XCTAssertFalse(manager.isPlaying)
    }
}

extension OpenRouterTTSCommissioningTests {
    func testPrecancelledCallerCannotInvalidateAnAlreadyActiveSynthesis() async throws {
        let fixture = try OpenRouterTTSCommissioningFixture()
        defer { fixture.cleanup() }
        let output = try fixture.result(name: "active-owner")
        let entered = expectation(description: "B owns active synthesis")
        let gate = OpenRouterTTSOperationGate(entered: entered)
        let option = try XCTUnwrap(OpenRouterProgressiveSpeechOption(selectionID: fixture.selection.id))
        var calls = 0
        let manager = fixture.manager(option: option) { text, _, _, _, _ in
            calls += 1
            XCTAssertEqual(text, "B")
            await gate.wait()
            return TTSSynthesisOutput(result: output, playbackCompleted: true)
        }
        defer { gate.release(); manager.stop() }
        let bSettled = expectation(description: "B succeeds after cancelled A is refused")
        var bOutcome: Result<TTSResult, Error>?
        let bTask = Task { @MainActor in
            do { bOutcome = .success(try await manager.synthesize(text: "B")) } catch { bOutcome = .failure(error) }
            bSettled.fulfill()
        }
        defer { bTask.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        let aSettled = expectation(description: "Precancelled A is refused at entry")
        var aOutcome: Result<TTSResult, Error>?
        let aTask = Task { @MainActor in
            do { aOutcome = .success(try await manager.synthesize(text: "A")) } catch { aOutcome = .failure(error) }
            aSettled.fulfill()
        }
        aTask.cancel()
        await fulfillment(of: [aSettled], timeout: 2)
        assertCancelled(aOutcome)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(manager.isSynthesizing)
        XCTAssertTrue(manager.isPlaying)
        gate.release()
        await fulfillment(of: [bSettled], timeout: 2)
        XCTAssertEqual(try XCTUnwrap(bOutcome).get().audioURL, output.audioURL)
        XCTAssertEqual(manager.lastResult?.audioURL, output.audioURL)
        XCTAssertEqual(manager.usageHistory.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.audioURL.path))
    }
}
