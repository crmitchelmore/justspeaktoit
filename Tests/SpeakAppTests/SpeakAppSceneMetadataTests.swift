import SwiftUI
import XCTest

@testable import SpeakApp

final class SpeakAppSceneMetadataTests: XCTestCase {
    @MainActor
    func testSceneMetadata_boundsNormalContentBeforeGraphInstantiation() {
        let application: any App.Type = SpeakApp.self
        let scene = Self.sceneMetadata(application)
        let description = String(reflecting: scene)

        XCTAssertTrue(description.contains("SwiftUI.AnyView"), description)
        XCTAssertFalse(description.contains("PaidAccessManager"), description)
    }

    // Resolve the associated-type witness just as SwiftUI's AppGraph does,
    // without constructing the app or starting its services and telemetry.
    @MainActor
    @inline(never)
    private static func sceneMetadata<Application: App>(_ application: Application.Type) -> Any.Type {
        Application.Body.self
    }
}
