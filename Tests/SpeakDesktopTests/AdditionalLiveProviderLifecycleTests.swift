import Foundation
@testable import SpeakCore
import XCTest

final class AdditionalLiveProviderLifecycleTests: XCTestCase {
    func testUpgradeFailureBeforeOpenIsReportedWithoutWaitingForReadiness() {
        for provider in AdditionalLiveProvider.allCases {
            let fixture = AdditionalLiveProviderFixture(provider)
            fixture.start()
            fixture.client.sendAudio(fixture.frame())
            fixture.socket.fail()
            if provider == .meta {
                XCTAssertEqual(fixture.factory.sockets.count, 2, "Meta retries one failed initial upgrade")
                fixture.socket.fail()
            }
            XCTAssertEqual(fixture.events.errors.count, 1, "\(provider)")
            for socket in fixture.factory.sockets {
                socket.open()
                XCTAssertTrue(socket.controls.isEmpty)
                XCTAssertTrue(socket.binary.isEmpty)
                XCTAssertEqual(socket.cancels, 1)
            }
            fixture.clock.fire(10)
            XCTAssertEqual(fixture.events.errors.count, 1, "Failure retired the readiness deadline")
        }
    }

    func testUnsolicitedReadinessAndDuplicateOpenCannotBypassOrRepeatSetup() {
        for provider in AdditionalLiveProvider.allCases {
            let fixture = AdditionalLiveProviderFixture(provider)
            fixture.start()
            fixture.client.sendAudio(fixture.frame())
            fixture.socket.emit(provider.ready)
            XCTAssertTrue(fixture.socket.controls.isEmpty)
            XCTAssertTrue(fixture.socket.binary.isEmpty)
            fixture.becomeReady()
            XCTAssertEqual(audioCount(fixture), 1, "\(provider)")
            let count = fixture.socket.controls.count + fixture.socket.binary.count
            fixture.socket.open()
            XCTAssertEqual(fixture.socket.controls.count + fixture.socket.binary.count, count)
            fixture.client.cancel()
        }
    }

    func testReadinessAndSingleFlightPreserveEveryFrameInOrder() {
        for provider in AdditionalLiveProvider.allCases {
            let fixture = AdditionalLiveProviderFixture(provider)
            fixture.start()
            fixture.client.sendAudio(fixture.frame(1))
            fixture.client.sendAudio(fixture.frame(2))
            XCTAssertTrue(fixture.socket.binary.isEmpty)
            fixture.becomeReady()
            XCTAssertEqual(audioCount(fixture), 1, "\(provider)")
            fixture.socket.completeSend()
            XCTAssertEqual(audioCount(fixture), 2, "\(provider)")
            fixture.socket.completeSend()
            fixture.client.cancel()
            XCTAssertTrue(fixture.events.errors.isEmpty)
        }
    }

    func testFinishDrainsThenSendsOneEndAndConsumesTheTrailingFinalOnce() async {
        for provider in AdditionalLiveProvider.allCases {
            let fixture = AdditionalLiveProviderFixture(provider)
            fixture.start()
            fixture.becomeReady()
            fixture.socket.emit(provider.final("Before."))
            fixture.client.sendAudio(fixture.frame(1))
            fixture.client.sendAudio(fixture.frame(2))
            let ended = expectation(description: "\(provider) end")
            fixture.socket.onSend = { if $0 == .text(provider.end) { ended.fulfill() } }
            let finish = Task { await fixture.client.finishAndWait() }
            fixture.socket.completeSend()
            XCTAssertFalse(fixture.socket.controls.contains(provider.end))
            fixture.socket.completeSend()
            await fulfillment(of: [ended], timeout: 2)
            fixture.socket.completeSend()
            fixture.socket.emit(provider.completion)
            let transcript = await finish.value
            XCTAssertEqual(
                transcript, provider == .grok ? "Tail." : provider == .modulate ? "Before." : "Before. Tail."
            )
            XCTAssertEqual(fixture.events.texts, ["Before."], "No trailing final is delivered twice")
            XCTAssertTrue(fixture.events.errors.isEmpty, "\(provider)")
            XCTAssertEqual(fixture.socket.controls.filter { $0 == provider.end }.count, 1)
            XCTAssertEqual(fixture.socket.cancels, 1)
        }
    }

    func testEarlyClosureAndFinishTimeoutFailBeforeReturningRecoveryText() async {
        for provider in AdditionalLiveProvider.allCases {
            for timeout in [false, true] {
                let fixture = AdditionalLiveProviderFixture(provider)
                fixture.start()
                fixture.becomeReady()
                fixture.socket.emit(provider.final("Recovered."))
                let ended = expectation(description: "\(provider) end")
                fixture.socket.onSend = { if $0 == .text(provider.end) { ended.fulfill() } }
                let finish = Task { await fixture.client.finishAndWait() }
                await fulfillment(of: [ended], timeout: 2)
                fixture.socket.completeSend()
                if timeout { fixture.clock.fire(provider.finishBudget) } else { fixture.socket.fail() }
                let transcript = await finish.value
                XCTAssertEqual(transcript, "Recovered.")
                XCTAssertEqual(fixture.events.errors.count, 1, "\(provider), timeout=\(timeout)")
                XCTAssertNotNil(fixture.events.errors.first as? ProviderStreamingError)
            }
        }
    }

    func testStopBeforeReadyWaitsForHandshakeAndRetainsCapturedAudio() async {
        for provider in AdditionalLiveProvider.allCases {
            let fixture = AdditionalLiveProviderFixture(provider)
            fixture.start()
            fixture.client.sendAudio(fixture.frame(7))
            let ended = expectation(description: "\(provider) end")
            fixture.socket.onSend = { if $0 == .text(provider.end) { ended.fulfill() } }
            let finish = Task { await fixture.client.finishAndWait() }
            fixture.becomeReady()
            XCTAssertEqual(audioCount(fixture), 1)
            fixture.socket.completeSend()
            await fulfillment(of: [ended], timeout: 2)
            fixture.socket.completeSend()
            fixture.socket.emit(provider.completion)
            _ = await finish.value
            XCTAssertTrue(fixture.events.errors.isEmpty)
        }
    }

    func testStalledSendAndBoundedAudioAdmissionSurfaceFailure() {
        for provider in AdditionalLiveProvider.allCases {
            for overflow in [false, true] {
                let fixture = AdditionalLiveProviderFixture(provider)
                fixture.start()
                fixture.becomeReady()
                fixture.client.sendAudio(fixture.frame())
                if overflow {
                    for _ in 0..<50 { fixture.client.sendAudio(fixture.frame()) }
                } else {
                    fixture.clock.fire(5)
                }
                XCTAssertEqual(fixture.events.errors.count, 1, "\(provider)")
                XCTAssertEqual(fixture.socket.cancels, 1)
                XCTAssertEqual(audioCount(fixture), 1, "No unbounded native send queue")
            }
        }
    }

    func testRestartIgnoresOldOpenReceiveSendAndDeadlineCallbacks() {
        for provider in AdditionalLiveProvider.allCases {
            let fixture = AdditionalLiveProviderFixture(provider)
            fixture.start()
            fixture.becomeReady()
            fixture.client.sendAudio(fixture.frame(1))
            let old = fixture.socket
            let deadlines = fixture.clock.drain()
            fixture.start()
            fixture.client.sendAudio(fixture.frame(2))
            old.completeSend()
            old.emit(provider.final("Retired."))
            old.open()
            deadlines.forEach { $0() }
            XCTAssertEqual(fixture.factory.sockets.count, 2)
            fixture.becomeReady()
            XCTAssertEqual(audioCount(fixture), 1)
            XCTAssertTrue(fixture.events.texts.isEmpty)
            XCTAssertTrue(fixture.events.errors.isEmpty)
            XCTAssertEqual(old.cancels, 1)
            fixture.client.cancel()
        }
    }

    func testTaskCancellationClosesOnceAndNeverResumesAReplacementFinish() async {
        for provider in AdditionalLiveProvider.allCases {
            let fixture = AdditionalLiveProviderFixture(provider)
            fixture.start()
            fixture.becomeReady()
            let ended = expectation(description: "\(provider) end")
            fixture.socket.onSend = { if $0 == .text(provider.end) { ended.fulfill() } }
            let finish = Task { await fixture.client.finishAndWait() }
            await fulfillment(of: [ended], timeout: 2)
            finish.cancel()
            _ = await finish.value
            fixture.client.cancel()
            XCTAssertEqual(fixture.socket.cancels, 1)
            XCTAssertTrue(fixture.events.errors.isEmpty)
        }
    }

    func testReadinessDeadlineFailsWithoutSubmittingQueuedAudio() {
        for provider in AdditionalLiveProvider.allCases {
            let fixture = AdditionalLiveProviderFixture(provider)
            fixture.start()
            fixture.client.sendAudio(fixture.frame())
            fixture.clock.fire(10)
            XCTAssertEqual(fixture.events.errors.count, 1)
            XCTAssertEqual(fixture.socket.cancels, 1)
            XCTAssertEqual(audioCount(fixture), 0)
        }
    }

    func testPendingFinishIsReleasedByRestartButLateFinalCannotMutateNewRun() async {
        for provider in AdditionalLiveProvider.allCases {
            let fixture = AdditionalLiveProviderFixture(provider)
            fixture.start()
            fixture.becomeReady()
            fixture.socket.emit(provider.final("Kept."))
            let old = fixture.socket
            let ended = expectation(description: "\(provider) end")
            old.onSend = { if $0 == .text(provider.end) { ended.fulfill() } }
            let finish = Task { await fixture.client.finishAndWait() }
            await fulfillment(of: [ended], timeout: 2)
            fixture.start()
            let text = await finish.value
            XCTAssertEqual(text, "Kept.")
            if let grok = fixture.client as? XAILiveClient {
                XCTAssertNil(grok.lastFinishOutcome, "The retired finish cannot publish an outcome for the new run")
            }
            old.completeSend()
            old.emit(provider.completion)
            fixture.becomeReady()
            XCTAssertEqual(fixture.events.texts, ["Kept."])
            XCTAssertTrue(fixture.events.errors.isEmpty)
            fixture.client.cancel()
        }
    }

    private func audioCount(_ fixture: AdditionalLiveProviderFixture) -> Int {
        if fixture.provider == .meta || fixture.provider == .modulate { return fixture.socket.binary.count }
        return fixture.socket.controls.filter {
            guard let object = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
                return false
            }
            let input = object["realtimeInput"] as? [String: Any]
            return object["type"] as? String == "input_audio_buffer.append" || input?["audio"] != nil
        }.count
    }
}
