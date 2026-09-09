import Foundation
import XCTest
@testable import SpeakCore

@MainActor
final class CaptureDisruptionObserverTests: XCTestCase {
    private let notificationName = Notification.Name("CaptureConfigurationChanged")

    func testOwnedDisruption_finalisesOnceAndIgnoresOtherEngines() async {
        let center = NotificationCenter()
        let engine = NSObject()
        let otherEngine = NSObject()
        let observer = CaptureDisruptionObserver(center: center)
        var finishes = 0
        var running = true
        observer.observe(notificationName, object: engine, isUsable: { running }, onDisruption: { finishes += 1 })
        center.post(name: notificationName, object: engine)
        await settle()
        XCTAssertEqual(finishes, 0, "Harmless configuration notification must keep capture active")
        running = false
        center.post(name: notificationName, object: otherEngine)
        await settle()
        XCTAssertEqual(finishes, 0)
        center.post(name: notificationName, object: engine)
        center.post(name: notificationName, object: engine)
        await settle()
        XCTAssertEqual(finishes, 1)
    }

    func testQueuedNotification_cannotStopReplacementCaptureOrWinAfterStop() async {
        let center = NotificationCenter()
        let engine = NSObject()
        let observer = CaptureDisruptionObserver(center: center)
        var oldFinishes = 0
        var newFinishes = 0
        observer.observe(notificationName, object: engine, isUsable: { false }, onDisruption: { oldFinishes += 1 })
        center.post(name: notificationName, object: engine)
        observer.stop()
        observer.observe(notificationName, object: engine, isUsable: { false }, onDisruption: { newFinishes += 1 })
        await settle()
        XCTAssertEqual(oldFinishes, 0)
        XCTAssertEqual(newFinishes, 0)
        center.post(name: notificationName, object: engine)
        await settle()
        XCTAssertEqual(newFinishes, 1)
    }

    func testObserverRelease_removesSubscriptionAndQueuedDelivery() async {
        let center = NotificationCenter()
        let engine = NSObject()
        var observer: CaptureDisruptionObserver? = CaptureDisruptionObserver(center: center)
        weak var released = observer
        var finishes = 0
        observer?.observe(notificationName, object: engine, isUsable: { false }, onDisruption: { finishes += 1 })
        center.post(name: notificationName, object: engine)
        observer = nil
        center.post(name: notificationName, object: engine)
        await settle()
        XCTAssertNil(released)
        XCTAssertEqual(finishes, 0)
    }

    private func settle() async {
        await Task { @MainActor in }.value
    }
}
