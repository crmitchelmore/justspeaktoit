import SpeakCore
import XCTest

@testable import SpeakApp

/// `AppSettings` normalises the persisted local streaming source lazily: resolving the catalogue
/// builds `LocalModelManager.shared`, whose initialiser creates directories, decodes the imported
/// models file and stats one marker file per catalogue model. None of that belongs on the launch
/// path.
final class AppSettingsLocalStreamingSourceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.speakapp.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// The catalogue is resolved lazily, so constructing settings must not build
    /// `LocalModelManager.shared` (its initialiser touches the filesystem on the launch path).
    @MainActor
    func testLocalStreamingSource_isNotResolvedWhileConstructingSettings() {
        let managersBefore = LocalModelManager.instanceCount
        var resolutions = 0
        AppSettings.localStreamingCatalogProvider = {
            resolutions += 1
            return AppSettings.LocalStreamingCatalog(supportedIDs: [], defaultID: "stub/default")
        }
        defer {
            AppSettings.localStreamingCatalogProvider = AppSettings.LocalStreamingCatalog.current
        }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(LocalModelManager.instanceCount, managersBefore)

        XCTAssertEqual(settings.localStreamingModelSource, "stub/default")
        XCTAssertEqual(resolutions, 1)

        // Second read comes from the cache.
        XCTAssertEqual(settings.localStreamingModelSource, "stub/default")
        XCTAssertEqual(resolutions, 1)
    }

    @MainActor
    func testLocalStreamingSource_invalidStoredValueNormalisesOnFirstRead() {
        defaults.set("local/streaming/does-not-exist", forKey: "localStreamingModelSource")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.localStreamingModelSource, Self.expectedDefaultStreamingSource)
    }

    @MainActor
    func testLocalStreamingSource_validStoredValueSurvivesFirstRead() throws {
        let supported = try XCTUnwrap(
            AppSettings.LocalStreamingCatalog.current().supportedIDs.sorted().first
        )
        defaults.set(supported, forKey: "localStreamingModelSource")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.localStreamingModelSource, supported)
    }

    @MainActor
    func testLocalStreamingSource_assignmentIsKeptVerbatimAndPersisted() {
        let settings = AppSettings(defaults: defaults)

        // The UI clears the selection with "" when the selected model is removed; normalising on
        // assignment would silently reselect the default.
        settings.localStreamingModelSource = ""

        XCTAssertEqual(settings.localStreamingModelSource, "")
        XCTAssertEqual(defaults.string(forKey: "localStreamingModelSource"), "")
    }

    @MainActor
    private static var expectedDefaultStreamingSource: String {
        FluidAudioModelManager.supportsCurrentHardware
          ? FluidAudioParakeetModel.id
          : LocalModelManager.shared.availableModels
            .filter(\.supportsLiveStreaming)
            .map(WhisperKitStreamingModel.id(for:))
            .first ?? ""
    }
}
