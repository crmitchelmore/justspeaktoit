import XCTest

@testable import SpeakiOSLib

final class AudioSessionActivationTests: XCTestCase {

    // The FourCC 'int' (cannotInterruptOthers) — the exact code AVAudioSession
    // reports when a background-triggered recording cannot activate its session.
    private let cannotInterruptOthersCode = 560_557_684 // '!int'

    // MARK: - Transient classification

    func testIsCannotInterruptOthers_bangIntCode_isTrue() {
        // Arrange
        let error = NSError(domain: NSOSStatusErrorDomain, code: cannotInterruptOthersCode)

        // Act
        let isTransient = AudioSessionActivation.isCannotInterruptOthers(error)

        // Assert
        XCTAssertTrue(isTransient)
    }

    func testIsCannotInterruptOthers_otherOSStatus_isFalse() {
        // Arrange
        let error = NSError(domain: NSOSStatusErrorDomain, code: 561_145_187) // '!rec'

        // Act
        let isTransient = AudioSessionActivation.isCannotInterruptOthers(error)

        // Assert
        XCTAssertFalse(isTransient)
    }

    func testIsCannotInterruptOthers_nonFourCCCode_isFalse() {
        // Arrange
        let error = NSError(domain: NSOSStatusErrorDomain, code: -50)

        // Act
        let isTransient = AudioSessionActivation.isCannotInterruptOthers(error)

        // Assert
        XCTAssertFalse(isTransient)
    }

    // MARK: - Retry loop

    func testActivate_succeedsAfterTransientFailures_retriesUntilSuccess() async throws {
        // Arrange: fail twice with '!int', then succeed on the third attempt.
        let interrupt = NSError(domain: NSOSStatusErrorDomain, code: cannotInterruptOthersCode)
        var attempts = 0
        var sleeps = 0

        // Act
        try await AudioSessionActivation.activate(
            maxAttempts: 4,
            sleep: { _ in sleeps += 1 },
            perform: {
                attempts += 1
                if attempts < 3 { throw interrupt }
            }
        )

        // Assert
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleeps, 2, "Should back off once between each of the two failed attempts")
    }

    func testActivate_persistentTransientFailure_throwsAfterMaxAttempts() async {
        // Arrange
        let interrupt = NSError(domain: NSOSStatusErrorDomain, code: cannotInterruptOthersCode)
        var attempts = 0

        // Act / Assert
        do {
            try await AudioSessionActivation.activate(
                maxAttempts: 3,
                sleep: { _ in },
                perform: {
                    attempts += 1
                    throw interrupt
                }
            )
            XCTFail("Expected activation to throw after exhausting retries")
        } catch {
            XCTAssertEqual(attempts, 3)
        }
    }

    func testActivate_nonTransientFailure_throwsImmediatelyWithoutRetry() async {
        // Arrange
        let fatal = NSError(domain: NSOSStatusErrorDomain, code: 561_145_187) // '!rec'
        var attempts = 0

        // Act / Assert
        do {
            try await AudioSessionActivation.activate(
                maxAttempts: 4,
                sleep: { _ in },
                perform: {
                    attempts += 1
                    throw fatal
                }
            )
            XCTFail("Expected non-transient error to propagate")
        } catch {
            XCTAssertEqual(attempts, 1, "Non-transient errors must not be retried")
        }
    }

    func testActivate_succeedsFirstAttempt_doesNotSleep() async throws {
        // Arrange
        var attempts = 0
        var sleeps = 0

        // Act
        try await AudioSessionActivation.activate(
            sleep: { _ in sleeps += 1 },
            perform: { attempts += 1 }
        )

        // Assert
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sleeps, 0)
    }
}
