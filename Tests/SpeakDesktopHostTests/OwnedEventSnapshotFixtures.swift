import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

actor OwnedEventLatch {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !signalled { await withCheckedContinuation { waiters.append($0) } }
    }

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class OwnedEventGestureFixture {
    let clock = DictationGestureClock()
    let entered = OwnedEventLatch()
    let release = OwnedEventLatch()
    let gestures: DesktopHostShortcutGestures<FakePlatform>
    let host: DesktopHostController<FakePlatform>
    let event: Task<DesktopHostRecordingEvent<FakePlatform>, Never>
    let index: Int

    init(
        host: DesktopHostController<FakePlatform>,
        event: Task<DesktopHostRecordingEvent<FakePlatform>, Never>, index: Int
    ) {
        self.host = host
        self.event = event
        self.index = index
        let entered = entered
        let release = release
        let clock = clock
        gestures = DesktopHostShortcutGestures(
            clock: { clock.now }, armDeadline: { _ in }, executablePath: { _ in "event-executable" },
            deliver: { request in
                await entered.signal()
                await release.wait()
                await host.admitShortcut(request)
            }
        )
        gestures.configure(style: .holdToRecord)
    }

    func hold() {
        let event = event
        gestures.keyDown(
            target: "event-field", textOutput: Task { await event.value.textOutput },
            modelIndex: index, deviceID: "event-device", event: event
        )
        clock.advance(1)
        gestures.deadlineReached()
    }

    func end() {
        clock.advance(0.05)
        gestures.keyUp()
    }

    func adopt() async {
        await release.signal()
        await gestures.drain()
        let startup = await host.ownedDictationAdmission?.operation
        await startup?.value
    }

    func finish() async {
        end()
        await gestures.drain()
        let stop = await host.ownedDictation?.stop
        await stop?.value
    }

    func unblock() async {
        await release.signal()
        await gestures.drain()
    }
}

extension DesktopHostController where Platform == FakePlatform {
    func ownedEventFixtureProfile(_ name: String) {
        let profile = DictationProfile(name: name)
        profiles = [profile]
        manualProfileID = profile.id
    }
}
