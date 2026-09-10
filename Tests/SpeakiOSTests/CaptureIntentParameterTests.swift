#if os(iOS)
import Foundation
import XCTest

@testable import SpeakiOSLib
import SpeakCore

/// The seam between the Shortcuts-facing parameter types and the settings
/// enums they stand for. The decisions themselves are pure and covered by
/// `CaptureParameterResolutionTests` on the host; what can only be checked
/// here is that the two vocabularies still line up.
@available(iOS 18, *)
final class CaptureIntentParameterTests: XCTestCase {
    /// A destination the picker can offer but the app cannot honour would send
    /// a transcript nowhere, so the two enums have to stay in step case for
    /// case, both ways.
    func testDestinationAppEnumCoversEverySettingsDestination() {
        let appEnumIDs = Set(CaptureDestinationAppEnum.allCases.map(\.rawValue))
        let settingsIDs = Set(HardwareTriggerDestination.allCases.map(\.rawValue))
        XCTAssertEqual(appEnumIDs, settingsIDs)
        for value in CaptureDestinationAppEnum.allCases {
            XCTAssertEqual(value.destination.rawValue, value.rawValue)
        }
    }

    func testEveryDestinationCaseHasADisplayRepresentation() {
        for value in CaptureDestinationAppEnum.allCases {
            XCTAssertNotNil(
                CaptureDestinationAppEnum.caseDisplayRepresentations[value],
                "\(value) would show as a blank row in Shortcuts"
            )
        }
    }

    /// The pickers are built from the catalogues rather than a second copy of
    /// them, so anything they offer must validate. If one ever did not, a user
    /// could pick a value from the app's own list and have the recording
    /// refused.
    func testEveryOfferedLanguageValidates() async throws {
        let offered = try await CaptureLanguageOptionsProvider().results()
        XCTAssertFalse(offered.isEmpty)
        for identifier in offered {
            XCTAssertEqual(
                CaptureParameterResolution.language(from: identifier),
                identifier,
                "\(identifier) is offered but would be refused"
            )
        }
    }

    func testEveryOfferedModelValidates() async throws {
        let offered = try await CaptureModelOptionsProvider().results()
        XCTAssertFalse(offered.isEmpty)
        XCTAssertEqual(Set(offered).count, offered.count, "the model picker lists a duplicate")
        for identifier in offered {
            XCTAssertEqual(
                CaptureParameterResolution.model(from: identifier),
                identifier,
                "\(identifier) is offered but would be refused"
            )
        }
    }
}

/// A capture started with no parameters must finish exactly where it did
/// before parameters existed.
@available(iOS 18, *)
@MainActor
final class CaptureRunDestinationTests: XCTestCase {
    func testAnUnparameterisedRunFallsBackToTheGlobalSetting() {
        let service = TranscriptionRecordingService.shared
        XCTAssertNil(service.runDestinationOverride)
        XCTAssertEqual(
            service.resolvedStopDestination(),
            AppSettings.shared.hardwareTriggerDestination
        )
    }

    func testAnExplicitStopDestinationWins() {
        let service = TranscriptionRecordingService.shared
        XCTAssertEqual(service.resolvedStopDestination(explicit: .historyOnly), .historyOnly)
    }
}
#endif
