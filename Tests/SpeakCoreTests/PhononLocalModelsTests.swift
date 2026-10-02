import XCTest
@testable import SpeakCore

final class PhononLocalModelsTests: XCTestCase {
    func testPhononRequiresDirectDistributionAndAppleSilicon() {
        XCTAssertTrue(PhononLocalModels.isSupported(channel: .direct, isAppleSilicon: true))
        XCTAssertFalse(PhononLocalModels.isSupported(channel: .direct, isAppleSilicon: false))
        XCTAssertFalse(PhononLocalModels.isSupported(channel: .appStore, isAppleSilicon: true))
    }

    func testPhononHasCanonicalIdentityAndBatchOnlyCapability() throws {
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first { $0.engine == .phonon })
        XCTAssertEqual(model, PhononLocalModels.phonon2)
        XCTAssertEqual(ModelRouting.family(for: model.id), .downloadedLocal(engine: .phonon))
        XCTAssertEqual(ModelCatalog.friendlyName(for: model.id), "Phonon-2")
        XCTAssertFalse(model.supportsLiveStreaming)
        XCTAssertEqual(try JSONDecoder().decode(LocalTranscriptionEngine.self,
            from: JSONEncoder().encode(model.engine)), .phonon)
    }

    func testAvailableProjectionKeepsWhisperKitAndPrefersSupportedPhonon() {
        let available = ModelCatalog.availableLocalTranscription
        XCTAssertEqual(available.contains(PhononLocalModels.phonon2),
                       PhononLocalModels.isSupportedOnCurrentPlatform)
        if PhononLocalModels.isSupportedOnCurrentPlatform {
            XCTAssertEqual(available.first, PhononLocalModels.phonon2)
        }
        XCTAssertEqual(available.filter { $0.engine == .whisperKit },
                       ModelCatalog.localTranscription.filter { $0.engine == .whisperKit })
    }
}
