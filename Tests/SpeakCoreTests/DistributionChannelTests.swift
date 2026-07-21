import XCTest

@testable import SpeakCore

/// Verifies the `DistributionChannel` availability matrix — the single source of
/// truth for which features a build exposes. These are behavioural checks on the
/// policy, independent of which flavour the test binary itself was compiled as.
final class DistributionChannelTests: XCTestCase {

    // MARK: - Availability matrix

    func testDirectChannel_supportsAllGatedFeatures() {
        // Arrange
        let channel = DistributionChannel.direct

        // Act & Assert
        XCTAssertTrue(channel.supportsSelfUpdate)
        XCTAssertTrue(channel.supportsDownloadedCoreMLModels)
        XCTAssertTrue(channel.supportsExternalLocalModelRuntime)
        XCTAssertFalse(channel.supportsEncryptedCloudKitKeySync)
        XCTAssertFalse(channel.supportsICloudSync)
        XCTAssertEqual(channel.apiKeyStorageMode, .localKeychainOnly)
        XCTAssertTrue(channel.supportsAutomaticAccessibilityPrompt)
        XCTAssertTrue(channel.allowsCrossChannelMessaging)
        XCTAssertFalse(channel.isSandboxed)
    }

    func testAppStoreChannel_gatesSandboxRestrictedFeatures() {
        // Arrange
        let channel = DistributionChannel.appStore

        // Act & Assert
        XCTAssertFalse(channel.supportsSelfUpdate,
            "App Store builds update through the store, not Sparkle")
        XCTAssertTrue(channel.supportsDownloadedCoreMLModels,
            "WhisperKit/Core ML model data can run through the bundled in-process runtime")
        XCTAssertFalse(channel.supportsExternalLocalModelRuntime,
            "Executable local-model runtimes cannot run in the App Store sandbox")
        XCTAssertTrue(channel.supportsEncryptedCloudKitKeySync)
        XCTAssertTrue(channel.supportsICloudSync)
        XCTAssertEqual(channel.apiKeyStorageMode, .encryptedCloudKit)
        XCTAssertFalse(channel.supportsAutomaticAccessibilityPrompt,
            "Sandboxed apps cannot auto-prompt for Accessibility/Input Monitoring")
        XCTAssertFalse(channel.allowsCrossChannelMessaging,
            "App Store builds must not advertise other distribution channels")
        XCTAssertTrue(channel.isSandboxed)
    }

    func testSupports_isConsistentWithNamedConveniences() {
        // Arrange / Act / Assert
        for channel in DistributionChannel.allCases {
            XCTAssertEqual(channel.supports(.selfUpdate), channel.supportsSelfUpdate)
            XCTAssertEqual(channel.supports(.downloadedCoreMLModels), channel.supportsDownloadedCoreMLModels)
            XCTAssertEqual(channel.supports(.externalLocalModelRuntime), channel.supportsExternalLocalModelRuntime)
            XCTAssertEqual(channel.supports(.automaticAccessibilityPrompt),
                           channel.supportsAutomaticAccessibilityPrompt)
            XCTAssertEqual(channel.supports(.crossChannelMessaging),
                           channel.allowsCrossChannelMessaging)
            XCTAssertEqual(channel.supports(.encryptedCloudKitKeySync),
                           channel.supportsEncryptedCloudKitKeySync)
        }
    }

    // MARK: - Current build

    func testCurrent_matchesCompiledFlavour() {
        // Arrange
        let channel = DistributionChannel.current

        // Act & Assert — `current` is derived from compile-time flags, so it must be
        // one of the two known channels and its sandbox state must agree.
        #if os(iOS)
        XCTAssertEqual(channel, .appStore, "iOS always ships through the App Store")
        #elseif APP_STORE
        XCTAssertEqual(channel, .appStore)
        #else
        XCTAssertEqual(channel, .direct)
        #endif
        XCTAssertEqual(channel.isSandboxed, channel == .appStore)
    }

    func testDisplayNames_areDistinct() {
        // Arrange / Act / Assert
        XCTAssertEqual(DistributionChannel.direct.displayName, "Direct Download")
        XCTAssertEqual(DistributionChannel.appStore.displayName, "App Store")
    }
}
