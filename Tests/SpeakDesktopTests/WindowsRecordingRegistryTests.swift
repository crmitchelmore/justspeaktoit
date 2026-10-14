#if os(Windows) || SPEAK_WINDOWS_TARGET
import Foundation
import SpeakWindowsPlatform
import XCTest
@testable import SpeakDesktop

final class WindowsRecordingRegistryTests: XCTestCase {
    func testUnqualifiedIdentityFactoryFailsBeforeCreatingNamespace() throws {
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        XCTAssertThrowsError(try DesktopLocalRecordingPersistence.initialize(
            historyDirectory: fixture.history, using: WindowsRecordingRegistry.factory
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.history.appendingPathComponent(".recording-locations").path
        ))
    }

    func testNativeClosedWriterQualificationFixture() throws {
        #if os(Windows)
        let fixture = try RecordingLocationFixture()
        defer { try? fixture.clean() }
        try WindowsRecordingRegistry.runQualificationFixture(
            history: fixture.root.appendingPathComponent("Synthetic Native History", isDirectory: true)
        )
        #else
        throw XCTSkip("Stub graph compilation is not Windows native runtime qualification.")
        #endif
    }
}
#endif
