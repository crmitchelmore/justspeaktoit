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
        let vocabulary = CaptureModelSupport.vocabulary
        for identifier in offered {
            XCTAssertEqual(
                CaptureParameterResolution.model(from: identifier),
                identifier,
                "\(identifier) is offered but would be refused"
            )
            XCTAssertEqual(
                try CaptureParameterResolution.resolve(
                    model: identifier,
                    vocabulary: vocabulary
                ).modelID,
                identifier,
                "\(identifier) is offered but the intent vocabulary refuses it"
            )
        }
    }

    /// The picker used to hand out the whole cross-platform catalogue, which
    /// includes streaming providers and batch entries with no iOS route. Every
    /// offered value must be runnable in the mode it would run in.
    func testEveryOfferedModelHasAniOSExecutionPath() async throws {
        let offered = try await CaptureModelOptionsProvider().results()
        for identifier in offered {
            let usesBatch = CaptureParameterResolution.requiresBatchMode(identifier)
            XCTAssertTrue(
                CaptureModelSupport.canRun(identifier, usesBatch: usesBatch),
                "\(identifier) is offered but has no iOS \(usesBatch ? "batch" : "live") route"
            )
        }
    }

    /// A catalogue model iOS cannot execute is refused at resolution, before
    /// any microphone is opened, rather than accepted and then run through a
    /// different route.
    func testACatalogueModelWithNoIOSRouteIsRefused() throws {
        let executable = Set(CaptureModelSupport.executableModelIDs)
        let catalogue = ModelCatalog.liveTranscription
            + ModelCatalog.batchTranscription
            + ModelCatalog.localTranscriptionOptions
        guard let unsupported = catalogue.map(\.id).first(where: { !executable.contains($0) }) else {
            throw XCTSkip("every catalogue model has an iOS route")
        }
        // It still spells correctly against the shared catalogue...
        XCTAssertEqual(CaptureParameterResolution.model(from: unsupported), unsupported)
        // ...but the intent surface refuses it.
        XCTAssertThrowsError(
            try CaptureParameterResolution.resolve(
                model: unsupported,
                vocabulary: CaptureModelSupport.vocabulary
            )
        ) { error in
            XCTAssertEqual(error as? CaptureParameterFailure, .modelUnsupported)
        }
    }

    /// Every destination the picker offers is in the vocabulary the resolver
    /// accepts, and anything else is refused rather than silently becoming the
    /// global setting.
    func testDestinationVocabularyMatchesTheSettingsEnum() throws {
        for value in CaptureDestinationAppEnum.allCases {
            XCTAssertEqual(
                try CaptureParameterResolution.resolve(
                    destinationID: value.rawValue,
                    vocabulary: CaptureModelSupport.vocabulary
                ).destinationID,
                value.rawValue
            )
        }
        XCTAssertThrowsError(
            try CaptureParameterResolution.resolve(
                destinationID: "somewhere-else",
                vocabulary: CaptureModelSupport.vocabulary
            )
        ) { error in
            XCTAssertEqual(error as? CaptureParameterFailure, .unknownDestination)
        }
    }

    /// The compatibility guarantee: a saved Shortcut that sets nothing still
    /// resolves to `.none` under the narrowed vocabulary.
    func testASavedShortcutWithNoParametersIsUnaffectedByTheVocabulary() throws {
        XCTAssertEqual(
            try CaptureParameterResolution.resolve(vocabulary: CaptureModelSupport.vocabulary),
            .none
        )
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

/// A named model decides the mode it runs in. Letting the Settings toggle
/// stand for a live-only identifier is how a named model reached the batch
/// uploader, whose router falls through to OpenRouter for anything it does not
/// recognise.
@available(iOS 18, *)
@MainActor
final class CaptureRunModelSelectionTests: XCTestCase {
    private var liveOnlyModel: String {
        get throws {
            let batch = CaptureModelSupport.batchModelIDs
            return try XCTUnwrap(
                CaptureModelSupport.executableModelIDs.first { !batch.contains($0) },
                "no iOS live-only model to test with"
            )
        }
    }

    func testARequestedLiveModelStaysLiveEvenWhenSettingsSayBatch() throws {
        let settings = AppSettings.shared
        let previousMode = settings.transcriptionMode
        defer { settings.transcriptionMode = previousMode }
        settings.transcriptionMode = .batch

        let model = try liveOnlyModel
        let selection = TranscriptionRecordingService.modelSelection(
            keyboardProfile: nil,
            parameters: CaptureRunParameters(modelID: model),
            settings: settings
        )
        XCTAssertEqual(selection.modelID, model)
        XCTAssertFalse(
            selection.usesBatch,
            "a live-capable named model must not be uploaded through the batch route"
        )
        XCTAssertTrue(CaptureModelSupport.canRun(selection.modelID, usesBatch: selection.usesBatch))
    }

    /// The compatibility guarantee: with no model parameter the configured
    /// mode and model are used exactly as before.
    func testNoModelParameterKeepsTheConfiguredModeAndModel() {
        let settings = AppSettings.shared
        let previousMode = settings.transcriptionMode
        defer { settings.transcriptionMode = previousMode }

        settings.transcriptionMode = .batch
        let batch = TranscriptionRecordingService.modelSelection(
            keyboardProfile: nil,
            parameters: .none,
            settings: settings
        )
        XCTAssertTrue(batch.usesBatch)
        XCTAssertEqual(batch.modelID, settings.batchTranscriptionModel)

        settings.transcriptionMode = .streaming
        let live = TranscriptionRecordingService.modelSelection(
            keyboardProfile: nil,
            parameters: .none,
            settings: settings
        )
        XCTAssertFalse(live.usesBatch)
        XCTAssertEqual(live.modelID, settings.selectedModel)
    }
}
#endif
