import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopLocalStreamingCallbackTests: XCTestCase {
    private struct Recognizer: DesktopLocalRecognizer {
        func transcribe(
            samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?
        ) async throws -> String { "synthetic" }
    }

    private final class CallbackGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var released = false

        func hold() {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(10)
            while !released {
                let signaled = condition.wait(until: deadline)
                if !released, !signaled { return XCTFail("Synthetic callback gate timed out") }
            }
        }

        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var all: [String] { lock.withLock { values } }
        func record(_ value: String) { lock.withLock { values.append(value) } }
    }

    func testOverflow_CannotOvertakeAnAdmittedInterimOrFinalCallback() async {
        for initialFrames in [1, 10] {
            let entered = expectation(description: "transcript callback admitted")
            let failed = expectation(description: "terminal error follows admitted callback")
            let gate = CallbackGate()
            let events = Events()
            let client = DesktopLocalStreamingClient(
                recognizer: Recognizer(), model: WhisperCppModels.all[0],
                modelFile: URL(fileURLWithPath: "model.bin"), language: nil,
                tuning: .init(interimInterval: 0.1, maximumWindow: 1)
            )
            defer { gate.release(); client.cancel() }
            client.start(onTranscript: { _, _ in
                entered.fulfill()
                gate.hold()
                events.record("text")
            }, onError: {
                XCTAssertEqual($0 as? DesktopLocalTranscriptionError, .streamingBacklogExceeded)
                events.record("error")
                failed.fulfill()
            })
            let frame = Data(repeating: 0x20, count: 3_200)
            client.sendAudio(Data(repeating: 0x20, count: frame.count * initialFrames))
            await fulfillment(of: [entered], timeout: 5)
            for _ in 0..<31 { client.sendAudio(frame) }
            XCTAssertTrue(events.all.isEmpty, "Failure cannot pass the admitted but not yet published transcript")
            let finished = expectation(description: "failed finish does not join a held callback")
            let finish = Task {
                let result = await client.finishAndWait()
                XCTAssertEqual(result, initialFrames == 10 ? "synthetic" : nil)
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 1)
            gate.release()
            await fulfillment(of: [failed], timeout: 5)
            await finish.value
            XCTAssertEqual(events.all, ["text", "error"])
        }
    }
}
