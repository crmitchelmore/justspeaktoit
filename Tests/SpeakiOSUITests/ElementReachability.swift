import XCTest

/// Existence is not reachability. On a loaded hosted Simulator a control can
/// exist while its sheet is still sliding in, its list is still moving, or it
/// sits under a bar, and a tap sent then is silently dropped (issue #1431).
/// These helpers tap only a control whose frame is inside the usable screen
/// and has stopped moving, and re-tap a bounded number of times when the tap
/// did not take effect.
extension XCUIElement {
    /// The frame from a single snapshot, or nil when the element is gone.
    /// Unlike `frame`, a missing element does not record a test failure.
    var snapshotFrame: CGRect? {
        guard let frame = (try? self.snapshot())?.frame, !frame.isEmpty else { return nil }
        return frame
    }

    /// `isHittable` records a failure instead of returning false when the
    /// element has no on-screen activation point, as Skip did while its sheet
    /// was still being presented (run 42437254485). Ask it only once a
    /// snapshot puts the element's centre inside `window`.
    func isHittable(within window: CGRect) -> Bool {
        guard let frame = self.snapshotFrame,
              window.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        return self.isHittable
    }
}

/// Polled from an `NSPredicate`, so it is reached from XCTest's waiter only.
final class FrameSettleTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var last: CGRect?

    /// True once two consecutive polls observe the same frame.
    func isSettled(_ frame: CGRect?) -> Bool {
        self.lock.withLock {
            defer { self.last = frame }
            guard let frame else { return false }
            return frame == self.last
        }
    }
}

extension XCUIApplication {
    var windowFrame: CGRect {
        self.windows.firstMatch.snapshotFrame ?? .zero
    }

    /// The screen minus the navigation bar and the bottom bar/home indicator.
    /// `isHittable` only needs an element's centre on screen; a row half under
    /// the home indicator passed it and its tap never navigated (run 42283665401).
    var usableBand: CGRect {
        let window = self.windowFrame
        return CGRect(x: window.minX, y: window.minY + 120, width: window.width, height: window.height - 200)
    }

    /// Waits until `element` lies wholly inside `band`, is hittable there and
    /// its frame is unchanged between two polls (sheet, push or scroll settled).
    func waitUntilSettled(_ element: XCUIElement, inside band: CGRect, timeout: TimeInterval) -> Bool {
        let tracker = FrameSettleTracker()
        let window = self.windowFrame
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = element.snapshotFrame.flatMap { band.contains($0) ? $0 : nil }
            return tracker.isSettled(frame) && element.isHittable(within: window)
        }, object: nil)
        return XCTWaiter.wait(for: [settled], timeout: timeout) == .completed
    }

    /// Scrolls `element` wholly into the usable band and waits for it to settle.
    func reveal(_ element: XCUIElement, attempts: Int = 8, settleTimeout: TimeInterval = 5) -> Bool {
        let band = self.usableBand
        for _ in 0..<attempts {
            guard let frame = element.snapshotFrame else {
                self.swipeUp()
                continue
            }
            if band.contains(frame) {
                if self.waitUntilSettled(element, inside: band, timeout: settleTimeout) { return true }
                continue
            }
            // A full swipe overshoots the band in both directions (run 42302311943
            // attempt 2), so drag by the measured distance and hold to stop momentum.
            let delta = max(-(band.height - 40), min(band.height - 40, band.midY - frame.midY))
            let startY = delta > 0 ? band.minY + 20 : band.maxY - 20
            let start = self.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: band.midX, dy: startY))
            start.press(
                forDuration: 0.1,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)),
                withVelocity: .slow,
                thenHoldForDuration: 0.3
            )
        }
        return self.waitUntilSettled(element, inside: band, timeout: settleTimeout)
    }

    /// Reveals and taps `element` until `outcome` appears. A dropped tap is
    /// re-sent only while `outcome` is still absent and `element` is still
    /// reachable, so a slow but successful tap is never repeated elsewhere.
    /// Pass `inChrome` for fixed bar controls, which are settled, not scrolled.
    @discardableResult
    func tap(
        _ element: XCUIElement,
        until outcome: XCUIElement,
        inChrome: Bool = false,
        attempts: Int = 3,
        timeout: TimeInterval = 15
    ) -> Bool {
        for _ in 0..<attempts {
            if outcome.exists { return true }
            let reachable = inChrome
                ? self.waitUntilSettled(element, inside: self.windowFrame, timeout: 5)
                : self.reveal(element)
            guard reachable else { break }
            element.tap()
            if outcome.waitForExistence(timeout: timeout) { return true }
        }
        return outcome.exists
    }
}
