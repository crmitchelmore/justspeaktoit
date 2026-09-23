#if os(Windows)
import CWindowsSupport
import XCTest

final class WindowsAudioDeviceMonitorTests: XCTestCase {
    func testRapidChangesAndShutdown_CoalesceAndDrainWithoutHardware() {
        var error = [CChar](repeating: 0, count: 1_024)
        XCTAssertEqual(jsti_audio_device_monitor_self_test(&error, error.count), 0, String(cString: error))
    }

    func testMissingCallback_FailsWithoutCreatingAWorker() {
        var error = [CChar](repeating: 0, count: 1_024)
        XCTAssertNil(jsti_audio_device_monitor_create(nil, nil, &error, error.count))
        XCTAssertFalse(String(cString: error).isEmpty)
        jsti_audio_device_monitor_cancel(nil)
        XCTAssertEqual(jsti_audio_device_monitor_destroy(nil, &error, error.count), 0)
    }
}
#endif
