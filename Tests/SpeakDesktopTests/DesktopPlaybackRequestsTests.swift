import Foundation
import XCTest
@testable import SpeakDesktop

final class DesktopPlaybackRequestsTests: XCTestCase {
    func testNewerRequest_supersedesAndEndVoidsEveryIssuedTicket() {
        var requests = DesktopPlaybackRequests()
        let play = requests.begin()
        XCTAssertTrue(requests.isCurrent(play))
        let speech = requests.begin()
        XCTAssertFalse(requests.isCurrent(play))
        XCTAssertTrue(requests.isCurrent(speech))
        requests.end()
        XCTAssertFalse(requests.isCurrent(speech))
        let next = requests.begin()
        XCTAssertTrue(requests.isCurrent(next))
        XCTAssertNotEqual(next, speech)
    }

    /// Play resolves its record's audio before starting it. Stop in that
    /// suspension leaves the row selected, so re-checking the selection alone
    /// would still start audio after Stop; the ticket refuses it.
    func testStopWhileAStartResolvesItsAudio_voidsTheStart() async {
        let host = PlaybackRequestHost()
        let resolving = RequestGate()
        let play = Task { await host.play("A", resolving: resolving) }
        await resolving.waitUntilReached()
        await host.stop()
        await resolving.open()
        await play.value
        let selected = await host.selected
        XCTAssertEqual(selected, "A")
        let audible = await host.audible
        XCTAssertNil(audible, "the start resumed after Stop and played")
    }

    /// Recording and import end Read aloud and own the status line. The
    /// ended speech unwinds later, possibly after that work has finished,
    /// and must not overwrite its status.
    func testReadAloudEndedByOtherWork_neverReportsOverItsStatus() async {
        let host = PlaybackRequestHost()
        let speaking = RequestGate()
        let reading = Task { await host.readAloud("A", speaking: speaking) }
        await speaking.waitUntilReached()
        await host.endPlayback(status: "Import failed: the file is not audio.")
        await speaking.open()
        await reading.value
        let status = await host.status
        XCTAssertEqual(status, "Import failed: the file is not audio.")
    }

    func testReadAloudStillCurrent_reportsItsOutcome() async {
        let host = PlaybackRequestHost()
        let speaking = RequestGate()
        await speaking.open()
        await host.readAloud("A", speaking: speaking)
        let status = await host.status
        XCTAssertEqual(status, "Finished reading aloud.")
    }
}

/// The Windows host's use of the requests: Play re-checks its ticket after
/// resolving audio, and Read aloud reports only while its ticket is current.
private actor PlaybackRequestHost {
    private var requests = DesktopPlaybackRequests()
    private(set) var selected = "A"
    private(set) var audible: String?
    private(set) var status = ""

    func play(_ record: String, resolving: RequestGate) async {
        guard selected == record else { return }
        let request = requests.begin()
        await resolving.pass()
        guard requests.isCurrent(request), selected == record else { return }
        audible = record
    }

    func stop() {
        requests.end()
        audible = nil
    }

    func readAloud(_ record: String, speaking: RequestGate) async {
        let request = requests.begin()
        audible = record
        status = "Reading aloud…"
        await speaking.pass()
        guard requests.isCurrent(request) else { return }
        audible = nil
        status = "Finished reading aloud."
    }

    /// Recording or import: playback ends and this work owns the status.
    func endPlayback(status: String) {
        requests.end()
        audible = nil
        self.status = status
    }
}

/// Holds whatever reaches it until opened, and reports that it was reached.
private actor RequestGate {
    private var reached = false
    private var isOpen = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        reached = true
        reachWaiters.forEach { $0.resume() }
        reachWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { reachWaiters.append($0) }
    }

    func open() {
        isOpen = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }
}
