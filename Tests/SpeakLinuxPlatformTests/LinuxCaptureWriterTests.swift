import CLinuxSelfTest
import XCTest

/// The PulseAudio capture hands frames to a bounded ring drained by its own
/// writer thread, so Swift callbacks never run under the pulse main-loop lock.
final class LinuxCaptureWriterTests: XCTestCase {
    func testCaptureWriter_DeliversInOrderOffThreadAndReportsOverflowAfterAcceptedAudio() {
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(jsti_pcm_writer_self_test(&error, error.count), 0, String(cString: error))
    }
}
