import XCTest

@testable import SpeakApp

extension HotKeyPressPrimerTests {
    func testPressAfterDoubleTapWindow_DuringGrace_ReplacesThePreviousCapture() async {
        let environment = PrimerTestEnvironment()
        environment.keepsAlive = true
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await primer.settle()
        primer.pressEnded(at: 100.1)
        let staleDrop = environment.scheduler.entries.count - 1

        primer.pressBegan(at: 100.55)
        await primer.settle()
        environment.scheduler.entries[staleDrop].action()
        let reserved = await primer.reserve()?.value

        XCTAssertEqual(environment.opened.map(\.keyDownUptime), [100, 100.55])
        XCTAssertEqual(environment.closed.map(\.keyDownUptime), [100])
        XCTAssertEqual(reserved?.keyDownUptime, 100.55)
        XCTAssertEqual(primer.sequenceKeyDownUptime, 100.55)
    }

    func testPressAfterDoubleTapWindow_WhileOpening_ClosesBeforeStartingTheNewCapture() async {
        let environment = PrimerTestEnvironment()
        environment.keepsAlive = true
        environment.holdOpens = true
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await waitUntil { environment.pendingOpens.count == 1 }
        primer.pressEnded(at: 100.1)

        primer.pressBegan(at: 100.55)
        environment.resumeOpens()
        await waitUntil { environment.pendingOpens.count == 1 }
        XCTAssertEqual(environment.closed.map(\.keyDownUptime), [100])
        environment.resumeOpens()
        await primer.settle()
        let reserved = await primer.reserve()?.value

        XCTAssertEqual(reserved?.keyDownUptime, 100.55)
    }

    func testPressAfterDoubleTapWindow_WhenNowIneligible_ClosesThePreviousCapture() async {
        let environment = PrimerTestEnvironment()
        environment.keepsAlive = true
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await primer.settle()
        primer.pressEnded(at: 100.1)
        environment.isEligible = false

        primer.pressBegan(at: 100.55)
        await primer.settle()

        XCTAssertEqual(environment.opened.count, 1)
        XCTAssertEqual(environment.closed.count, 1)
        XCTAssertNil(primer.reserve())
    }
}
