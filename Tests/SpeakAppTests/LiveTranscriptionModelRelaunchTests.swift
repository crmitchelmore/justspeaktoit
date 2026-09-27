import XCTest

@testable import SpeakApp
@testable import SpeakCore

/// Relaunching the Mac app keeps the live model the user chose. Settings are
/// built over a WireUp test host's own preferences suite and root, with Dock
/// and login-item effects recorded rather than applied.
@MainActor
final class LiveTranscriptionModelRelaunchTests: XCTestCase {
    private var liveModelKey: String { AppSettings.DefaultsKey.liveTranscriptionModel.rawValue }

    /// Reported regression (justspeaktoit-iif.3.1): choosing either Deepgram
    /// Flux model and relaunching replaced it with Nova-3.
    func testDeepgramFluxSelections_surviveRelaunch() throws {
        let host = try makeWireUpTestHost()
        for flux in ["deepgram/flux-general-en-streaming", "deepgram/flux-general-multi-streaming"] {
            let settings = host.makeSettings()
            settings.liveTranscriptionModel = flux

            let relaunched = host.makeSettings()

            XCTAssertEqual(relaunched.liveTranscriptionModel, flux)
            XCTAssertEqual(relaunched.liveTranscriptionSelection.rememberedModel(for: .remote), flux)
        }
    }

    /// Every live catalogue entry, including entries added later, relaunches
    /// as saved: the Mac adds no migration of its own to the shared rule.
    func testEveryLiveCatalogueEntry_survivesRelaunch() throws {
        let host = try makeWireUpTestHost()
        for option in ModelCatalog.liveTranscription {
            host.defaults.set(option.id, forKey: liveModelKey)

            XCTAssertEqual(host.makeSettings().liveTranscriptionModel, option.id, option.id)
        }
    }

    /// Retired identifiers still move to the shared successor, in the active
    /// model and in the remote memory seeded from it.
    func testRetiredLiveIdentifiers_followTheSharedSuccessor() throws {
        let host = try makeWireUpTestHost()
        for (retired, successor) in ModelCatalog.liveTranscriptionSuccessors {
            host.defaults.set(retired, forKey: liveModelKey)
            host.defaults.removeObject(forKey: LiveTranscriptionSelection.DefaultsKey.remoteModel)

            let settings = host.makeSettings()

            XCTAssertEqual(settings.liveTranscriptionModel, successor, retired)
            XCTAssertEqual(settings.liveTranscriptionSelection.rememberedModel(for: .remote), successor, retired)
        }
    }

    /// The Mac deliberately supports custom remote models, including ones under
    /// a provider that also has catalogue entries.
    func testCustomRemoteModels_surviveRelaunch() throws {
        let host = try makeWireUpTestHost()
        for custom in ["deepgram/custom-streaming", "assemblyai/custom-streaming", "acme/realtime-v1"] {
            host.defaults.set(custom, forKey: liveModelKey)

            XCTAssertEqual(host.makeSettings().liveTranscriptionModel, custom, custom)
        }
    }
}
