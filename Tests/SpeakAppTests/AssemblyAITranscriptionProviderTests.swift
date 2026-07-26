import SpeakCore
@testable import SpeakApp
import XCTest

final class AssemblyAITranscriptionProviderTests: XCTestCase {
    func testSupportedModels_exposesUniversal35ProInPlaceOfUniversal3() {
        let ids = AssemblyAITranscriptionProvider().supportedModels().map(\.id)

        XCTAssertTrue(ids.contains(AssemblyAIModels.universal35ProBatchID))
        XCTAssertTrue(ids.contains(AssemblyAIModels.universal2BatchID))
        XCTAssertFalse(ids.contains("assemblyai/universal-3-pro"))
    }

    func testBatchModelMapping_usesUniversal35ProAndFallback() {
        let provider = AssemblyAITranscriptionProvider()

        XCTAssertEqual(
            provider.mapSpeechModels(from: AssemblyAIModels.universal35ProBatchID),
            [AssemblyAIModels.universal35ProAPIName, AssemblyAIModels.universal2APIName]
        )
        XCTAssertEqual(
            provider.mapSpeechModels(from: "assemblyai/universal-3-pro"),
            [AssemblyAIModels.universal35ProAPIName, AssemblyAIModels.universal2APIName]
        )
        XCTAssertEqual(
            provider.mapSpeechModels(from: "assemblyai/unknown"),
            [AssemblyAIModels.universal35ProAPIName, AssemblyAIModels.universal2APIName]
        )
    }
}
