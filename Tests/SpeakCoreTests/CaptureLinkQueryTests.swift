import XCTest
@testable import SpeakCore

/// The repeat policy for capture-link parameters, kept separate from the
/// callback-building tests it protects.
final class CaptureLinkQueryTests: XCTestCase {
    // MARK: - Repeated parameters

    func testASingleValueIsReadWhateverTheCase() throws {
        let items = [URLQueryItem(name: "Lang", value: "en_US")]
        XCTAssertEqual(try CaptureLinkQuery.singleValue("lang", in: items), "en_US")
        XCTAssertNil(try CaptureLinkQuery.singleValue("model", in: items))
    }

    func testRepeatingAParameterWithTheSameValueAsksForNothingAmbiguous() throws {
        let items = [
            URLQueryItem(name: "lang", value: "en_US"),
            URLQueryItem(name: "LANG", value: "en_US")
        ]
        XCTAssertEqual(try CaptureLinkQuery.singleValue("lang", in: items), "en_US")
    }

    func testAConflictingRepeatIsRefusedRatherThanResolvedToTheFirstValue() {
        // ?lang=en_US&lang=klingon is well-formed and carries two values.
        // Taking the first would record under en_US and never tell the caller
        // its unknown value was discarded — the one behaviour this vocabulary
        // promises not to have.
        let items = [
            URLQueryItem(name: "lang", value: "en_US"),
            URLQueryItem(name: "lang", value: "klingon")
        ]
        XCTAssertThrowsError(try CaptureLinkQuery.singleValue("lang", in: items)) { error in
            XCTAssertEqual(error as? CaptureLinkFailure, .repeatedParameter)
        }
        XCTAssertTrue(CaptureLinkQuery.hasConflictingRepeat("lang", in: items))
        XCTAssertFalse(CaptureLinkQuery.hasConflictingRepeat("model", in: items))
    }

    func testTwoDifferentSuccessCallbacksAreRefusedRatherThanOneChosen() {
        let items = [
            URLQueryItem(name: "x-success", value: "drafts://create?text="),
            URLQueryItem(name: "x-success", value: "bear://x-callback-url/create?text=")
        ]
        XCTAssertThrowsError(try CaptureCallback.parse(queryItems: items)) { error in
            XCTAssertEqual(
                error as? CaptureLinkFailure,
                .repeatedParameter,
                "A caller waiting at one of two addresses must be told, not sent to the first"
            )
        }
    }

    func testEveryFailureStillCarriesAMessageForTheCaller() {
        for failure in CaptureLinkFailure.allCases {
            XCTAssertFalse(
                (failure.errorDescription ?? "").isEmpty,
                "\(failure.rawValue) reaches a caller as errorMessage and a user as an alert"
            )
        }
    }
}
