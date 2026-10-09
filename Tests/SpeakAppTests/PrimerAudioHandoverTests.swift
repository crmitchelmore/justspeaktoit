import AVFoundation
import Foundation
import XCTest

@testable import SpeakApp

final class PrimerAudioHandoverTests: XCTestCase {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    private func buffer(_ value: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        for index in 0..<160 {
            buffer.floatChannelData![0][index] = value
        }
        return buffer
    }

    func testHandover_ReplaysPreRollBeforeForwardingAudioFromTheSameTap() {
        let preRoll = PrimerPreRollBuffer(maximumDuration: 1.5)
        preRoll.append(buffer(1), at: 1)
        preRoll.append(buffer(2), at: 2)
        var delivered: [Float] = []

        preRoll.startConsuming(preRollBuffers: [buffer(0)]) {
            delivered.append($0.floatChannelData![0][0])
        }
        preRoll.append(buffer(3), at: 3)

        XCTAssertEqual(delivered, [0, 1, 2, 3])
        XCTAssertEqual(preRoll.bufferedDuration, 0)
        XCTAssertTrue(preRoll.drain().isEmpty)
    }

    func testHandover_AudioArrivingDuringReplay_IsDeliveredAfterAllPreRoll() async {
        let preRoll = PrimerPreRollBuffer(maximumDuration: 1.5)
        preRoll.append(buffer(1), at: 1)
        preRoll.append(buffer(2), at: 2)
        let arriving = buffer(3)
        let captureStarted = DispatchSemaphore(value: 0)
        let captured = expectation(description: "audio arriving during replay is delivered")
        var delivered: [Float] = []

        preRoll.startConsuming(preRollBuffers: []) { buffer in
            let value = buffer.floatChannelData![0][0]
            delivered.append(value)
            if value == 1 {
                DispatchQueue.global().async {
                    captureStarted.signal()
                    preRoll.append(arriving, at: 3)
                    captured.fulfill()
                }
                XCTAssertEqual(captureStarted.wait(timeout: .now() + 2), .success)
            }
        }
        await fulfillment(of: [captured], timeout: 2)

        XCTAssertEqual(delivered, [1, 2, 3])
    }

    func testStopConsuming_DoesNotForwardAnInFlightTapAfterTeardown() {
        let preRoll = PrimerPreRollBuffer(maximumDuration: 1.5)
        var delivered = 0
        preRoll.startConsuming(preRollBuffers: []) { _ in delivered += 1 }
        preRoll.append(buffer(1), at: 1)

        preRoll.stopCollecting()
        preRoll.append(buffer(2), at: 2)

        XCTAssertEqual(delivered, 1)
    }
}
