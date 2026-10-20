import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class DesktopNativeConfigurationImportTests: XCTestCase {
    func testExistingMacImporter_RejectsNativeTransportRatherThanTreatingItAsGlobalPrompt() throws {
        let capture = try DesktopNativeConfigurationCapture.capture(
            ["postProcessing.customPrompt": AnyCodable(.string("source-native-global-prompt"))], platform: .windows,
            selectedFields: ["postProcessing.customPrompt"]
        )
        let projected = try DesktopNativeConfigurationArchiveCodec.project(capture)
        for record in projected.records {
            XCTAssertThrowsError(try MigrationCatalog.validate(record, category: .settings))
            XCTAssertThrowsError(try MigrationCatalog.validate(record, category: .profiles))
            XCTAssertNil(DataMigrationPreferenceCatalog.definition(for: record.id))
        }
    }
}
