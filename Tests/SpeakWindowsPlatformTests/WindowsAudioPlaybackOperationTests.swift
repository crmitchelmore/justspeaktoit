#if os(Windows)
import Foundation
import XCTest
@testable import SpeakWindowsPlatform

final class WindowsAudioPlaybackOperationTests: XCTestCase {
    func testImmediateSuccessAndFailure_DoNotDestroyBeforeStartReturns() async throws {
        for status in [WindowsAudioPlaybackCompletion.Status.finished, .failed("Immediate failure")] {
            let backend = PlaybackTestBackend(), gate = PlaybackTestGate()
            backend.enqueue(PlaybackTestPlan(startGate: gate, completeOnStart: .init(status: status, played: 0.1)))
            let task = Task {
                try await WindowsAudioPlayback.play(input: URL(fileURLWithPath: "/fixture.wav"), backend: backend)
            }
            await playbackEventually { gate.entered }
            let handle = try XCTUnwrap(backend.handles.first)
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertEqual(handle.counts.destroyAttempts, 0)
            gate.open()
            switch status {
            case .finished: let output = try await task.value; XCTAssertEqual(output.playedDuration, 0.1)
            default: do { _ = try await task.value; XCTFail("Expected failure") } catch {}
            }
            XCTAssertFalse(handle.destroyedBeforeStartReturn)
            XCTAssertEqual(handle.counts.destroyed, 1)
        }
    }

    func testCancellationWhileStartIsSuspended_WaitsForPublicationThenReleases() async throws {
        let backend = PlaybackTestBackend(), gate = PlaybackTestGate()
        backend.enqueue(PlaybackTestPlan(startGate: gate, completeOnStart: .init(status: .finished, played: 0.1)))
        let task = Task {
                try await WindowsAudioPlayback.play(input: URL(fileURLWithPath: "/fixture.wav"), backend: backend)
            }
        await playbackEventually { gate.entered }
        task.cancel()
        let handle = try XCTUnwrap(backend.handles.first)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(handle.counts.destroyAttempts, 0)
        gate.open()
        do {
            _ = try await task.value
            XCTFail("Cancellation was lost")
        } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(handle.counts.destroyed, 1)
        XCTAssertFalse(handle.destroyedBeforeStartReturn)
    }

    func testCancellationDuringOpen_PreventsStartAndReleasesAfterOpenReturns() async throws {
        let backend = PlaybackTestBackend(), gate = PlaybackTestGate()
        backend.enqueue(PlaybackTestPlan(openGate: gate))
        let task = Task {
                try await WindowsAudioPlayback.play(input: URL(fileURLWithPath: "/fixture.wav"), backend: backend)
            }
        await playbackEventually { gate.entered }
        task.cancel()
        gate.open()
        do {
            _ = try await task.value
            XCTFail("Cancellation was lost")
        } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(backend.handles.first?.counts.started, 0)
        XCTAssertEqual(backend.handles.first?.counts.destroyed, 1)
    }

    func testFailedRelease_RemainsOwnedAndRetriesOnNextInvocation() async throws {
        let first = PlaybackTestBackend()
        first.enqueue(PlaybackTestPlan(completeOnStart: .init(status: .finished, played: 0), destroyFailures: 1))
        do { _ = try await WindowsAudioPlayback.play(input: URL(fileURLWithPath: "/fixture.wav"), backend: first)
            XCTFail("Release failure was hidden")
        } catch { XCTAssertTrue(error.localizedDescription.contains("release failure")) }
        XCTAssertEqual(first.handles.first?.counts.destroyed, 0)
        let second = PlaybackTestBackend()
        second.enqueue(PlaybackTestPlan(completeOnStart: .init(status: .finished, played: 0)))
        _ = try await WindowsAudioPlayback.play(input: URL(fileURLWithPath: "/fixture.wav"), backend: second)
        await playbackEventually { first.handles.first?.counts.destroyed == 1 }
        XCTAssertEqual(second.handles.first?.counts.destroyed, 1)
    }
    func testTwoBlockedOperations_RejectFurtherAdmissionWithoutOpeningAnotherHandle() async throws {
        let first = PlaybackTestBackend(), second = PlaybackTestBackend(), rejected = PlaybackTestBackend()
        let gate1 = PlaybackTestGate(), gate2 = PlaybackTestGate()
        first.enqueue(PlaybackTestPlan(openGate: gate1, completeOnStart: .init(status: .finished, played: 0)))
        second.enqueue(PlaybackTestPlan(openGate: gate2, completeOnStart: .init(status: .finished, played: 0)))
        let url = URL(fileURLWithPath: "/fixture.wav")
        let firstTask = Task { try await WindowsAudioPlayback.play(input: url, backend: first) }
        let secondTask = Task { try await WindowsAudioPlayback.play(input: url, backend: second) }
        await playbackEventually { gate1.entered && gate2.entered }
        do { _ = try await WindowsAudioPlayback.play(input: url, backend: rejected)
            XCTFail("The global operation bound was exceeded")
        } catch {}
        XCTAssertTrue(rejected.handles.isEmpty)
        gate1.open()
        gate2.open()
        _ = try await firstTask.value
        _ = try await secondTask.value
    }

}
#endif
