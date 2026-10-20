import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class AppSwitchDeliveryTests: XCTestCase {
    func testCanonicalCatalogueAndLegacyProjectionRoundTrip() throws {
        XCTAssertEqual(AppSwitchDelivery.defaultValue, .originalApp)
        XCTAssertEqual(AppSwitchDelivery.preferenceKey, ApplicationPreferenceKey.appSwitchDelivery.rawValue)
        XCTAssertEqual(AppSwitchDelivery.allCases.map(\.rawValue),
                       ["originalApp", "currentApp", "onlyIfOriginalAppInFront"])
        XCTAssertNil(try AppSwitchDelivery.desktopPolicy(selection: 0))
        for policy in AppSwitchDelivery.allCases {
            XCTAssertEqual(
                try AppSwitchDelivery.desktopPolicy(selection: AppSwitchDelivery.desktopSelection(policy)), policy
            )
        }
        XCTAssertThrowsError(try AppSwitchDelivery.desktopPolicy(selection: -1))
        XCTAssertThrowsError(try AppSwitchDelivery.desktopPolicy(selection: AppSwitchDelivery.desktopChoices.count))
    }

    func testConfigurationRejectsUnknownAndNonStringPolicies() throws {
        let key = AppSwitchDelivery.preferenceKey
        for value in [AnyCodable(.string("otherApp")), AnyCodable(.bool(false)), AnyCodable(.double(1))] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [key: value]))
        }
        for choice in AppSwitchDelivery.desktopChoices {
            let configuration = try DesktopConfiguration(values: [key: AnyCodable(.string(choice.value))])
            XCTAssertEqual(configuration.text(key), choice.value)
        }
    }

    func testMissingImportDoesNotReplaceNativePolicyOrUnknownValues() throws {
        var options: any DesktopAppSwitchOutputOptions = PolicyOptions(appSwitchDelivery: .currentApp)
        let source = try DesktopConfiguration(values: ["future-key": AnyCodable(.string("retained"))])
        let result = try DesktopAppSwitchOutput.importPolicy(from: source, into: &options)
        XCTAssertEqual(options.appSwitchDelivery, .currentApp)
        XCTAssertEqual(result, source)
    }

    func testExplicitImportHasOneOwnerAndExportNeverFabricatesMissingIntent() throws {
        let key = AppSwitchDelivery.preferenceKey
        var options: any DesktopAppSwitchOutputOptions = PolicyOptions(appSwitchDelivery: nil)
        for policy in AppSwitchDelivery.allCases {
            let source = try DesktopConfiguration(values: [key: AnyCodable(.string(policy.rawValue))])
            let retained = try DesktopAppSwitchOutput.importPolicy(from: source, into: &options)
            XCTAssertNil(retained.values[key])
            XCTAssertEqual(options.appSwitchDelivery, policy)
            XCTAssertEqual(try DesktopAppSwitchOutput.project(policy, over: retained), source)
        }
        let empty = try DesktopConfiguration(values: [:])
        XCTAssertNil(try DesktopAppSwitchOutput.project(nil, over: empty).values[key])
        XCTAssertEqual(try DesktopAppSwitchOutput.project(nil, over: empty, editor: true).values[key],
                       AnyCodable(.string("")))
    }

    func testExplicitLegacyChoiceClearsNativeIntentWithoutBecomingMacDefault() throws {
        var options: any DesktopAppSwitchOutputOptions = PolicyOptions(appSwitchDelivery: .originalApp)
        let source = try DesktopConfiguration(values: [
            AppSwitchDelivery.preferenceKey: AnyCodable(.string(""))
        ])
        let retained = try DesktopAppSwitchOutput.importPolicy(from: source, into: &options)
        XCTAssertNil(options.appSwitchDelivery)
        XCTAssertNil(retained.values[AppSwitchDelivery.preferenceKey])
    }

    func testCapabilityCopyExplainsRetainedIntentAndLinuxTargetingGap() {
        XCTAssertTrue(AppSwitchDelivery.nativeHelp(canTargetApps: false).contains("copy only"))
        XCTAssertTrue(AppSwitchDelivery.nativeHelp(canTargetApps: false).contains("Legacy keeps"))
        XCTAssertTrue(AppSwitchDelivery.linuxHelp(canTargetApps: true).contains("newly selected app/field"))
    }
}

private struct PolicyOptions: DesktopAppSwitchOutputOptions {
    var appSwitchDelivery: AppSwitchDelivery?
}
