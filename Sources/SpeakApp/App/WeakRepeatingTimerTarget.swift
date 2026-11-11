import Foundation

@MainActor
protocol RepeatingTimerTarget: AnyObject {
    func repeatingTimerDidFire()
}

/// Keeps selector-based timers without making the run loop own the controller.
/// The timer retains this proxy; the proxy only weakly references its owner.
@MainActor
final class WeakRepeatingTimerTarget: NSObject {
    private weak var target: (any RepeatingTimerTarget)?

    private init(target: any RepeatingTimerTarget) {
        self.target = target
        super.init()
    }

    static func scheduledTimer(interval: TimeInterval, target: any RepeatingTimerTarget) -> Timer {
        let proxy = WeakRepeatingTimerTarget(target: target)
        return Timer.scheduledTimer(
            timeInterval: interval,
            target: proxy,
            selector: #selector(fire(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func fire(_ timer: Timer) {
        guard let target else {
            timer.invalidate()
            return
        }
        target.repeatingTimerDidFire()
    }
}
