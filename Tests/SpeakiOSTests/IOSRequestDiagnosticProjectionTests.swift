#if os(iOS)
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class IOSRequestDiagnosticProjectionTests: XCTestCase {
    func testGlobalAdmissionProjectsConsumedFieldsWithoutObservedProvider() throws {
        let context = IOSRequestDiagnosticProjection.admission(try configuration(), keyboardProfile: false)
        XCTAssertEqual(context.provenance, .admission)
        XCTAssertEqual(context.model.identifier, "gladia/solaria-1-streaming")
        XCTAssertEqual(context.mode, .live)
        XCTAssertEqual(context.origin, .global)
        XCTAssertEqual(context.language.identifier, "en_US")
        XCTAssertEqual(context.destination, .clipboard)
        XCTAssertNil(context.observedProvider)
        XCTAssertNil(context.options.postProcessingEnabled)
    }

    func testMixedOriginsAndKeyboardCannotClaimOneGlobalSource() throws {
        let mixed = try configuration(explicit: .init(modelID: "gladia/solaria-1-streaming"))
        XCTAssertEqual(IOSRequestDiagnosticProjection.admission(mixed, keyboardProfile: false).origin, .unknown)
        XCTAssertEqual(IOSRequestDiagnosticProjection.admission(try configuration(), keyboardProfile: true).origin,
                       .unknown)
    }

    func testExplicitAndFocusSourcesAreOnlyClaimedWhenAllFieldsAgree() throws {
        let fields = CaptureRunParameters(destinationID: "historyOnly", languageIdentifier: "en_US",
                                          modelID: "gladia/solaria-1-streaming")
        let explicit = IOSRequestDiagnosticProjection.admission(try configuration(explicit: fields),
                                                               keyboardProfile: false)
        XCTAssertEqual(explicit.origin, .explicitOverride)
        XCTAssertEqual(explicit.destination, .history)
        let focus = try configuration(focus: .init(destinationID: "historyOnly",
                                                   modelID: "gladia/solaria-1-streaming", languageIdentifier: "en_US"))
        XCTAssertEqual(IOSRequestDiagnosticProjection.admission(focus, keyboardProfile: false).origin, .focusOverride)
    }

    func testAutomaticDestinationStaysUnknownAndDoesNotInventDeliveryOrPolish() throws {
        let configuration = try configuration(destination: "auto")
        let context = IOSRequestDiagnosticProjection.admission(configuration, keyboardProfile: false)
        XCTAssertEqual(context.destination, .unknown)
        XCTAssertNil(context.options.postProcessingEnabled)
        XCTAssertNil(context.postProcessingModel.identifier)
    }

    func testForegroundCopiesOnlyTheSelectedModelWithoutReadingOtherSettings() {
        let context = IOSRequestDiagnosticProjection.foreground(modelID: "gladia/solaria-1-streaming")
        XCTAssertEqual(context.model.identifier, "gladia/solaria-1-streaming")
        XCTAssertEqual(context.mode, .unknown)
        XCTAssertEqual(context.origin, .unknown)
        XCTAssertEqual(context.destination, .unknown)
        XCTAssertNil(context.language.identifier)
        XCTAssertNil(context.observedProvider)
    }

    func testLocalSessionHandoffDoesNotClaimProviderLanguageOptionsOrRemoteAcceptance() {
        let context = IOSRequestDiagnosticProjection.handoff(.init(
            modelID: "gladia/solaria-1-streaming", backend: .shared(.gladia), route: nil
        ))
        XCTAssertEqual(context.provenance, .observedHandoff)
        XCTAssertEqual(context.model.identifier, "gladia/solaria-1-streaming")
        XCTAssertEqual(context.mode, .live)
        XCTAssertNil(context.observedProvider)
        XCTAssertNil(context.language.identifier)
        XCTAssertNil(context.options.finalizationBudgetMilliseconds)
    }

    func testUntrustedGlobalIdentifiersCannotEnterAnySerializedReportSurface() throws {
        let canaries = ["custom/CANARY-model", "CANARY-language", "CANARY-destination"]
        let configuration = try EffectiveCaptureConfiguration.resolve(
            explicit: .none, focus: .none,
            globals: .init(modelID: canaries[0], usesBatch: true,
                           languageIdentifier: canaries[1], destinationID: canaries[2]),
            vocabulary: .unconstrained
        )
        let context = IOSRequestDiagnosticProjection.admission(configuration, keyboardProfile: false)
        let snapshot = IOSIssueReportSnapshot(context: context, observedHandoff: nil, requestFailure: .init())
        for report in [snapshot.full, snapshot.withoutDetails] {
            for canary in canaries {
                XCTAssertFalse(report.jsonString.contains(canary))
                XCTAssertFalse(report.body.contains(canary))
                XCTAssertFalse(report.issueURL?.absoluteString.contains(canary) == true)
            }
        }
        XCTAssertEqual(context.model.classification, .customOrUnknown)
        XCTAssertNil(context.language.identifier)
        XCTAssertEqual(context.destination, .unknown)
    }

    private func configuration(
        explicit: CaptureRunParameters = .none, focus: FocusCaptureOverride = .none,
        destination: String = "clipboard"
    ) throws -> EffectiveCaptureConfiguration {
        try EffectiveCaptureConfiguration.resolve(
            explicit: explicit, focus: focus,
            globals: .init(modelID: "gladia/solaria-1-streaming", usesBatch: false,
                           languageIdentifier: "en_US", destinationID: destination),
            vocabulary: .unconstrained
        )
    }
}
#endif
