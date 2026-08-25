import Foundation
import XCTest

// swiftlint:disable:next type_body_length
final class DistributionBuildIdentityTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testMacDistributionChannels_useDistinctBundleIdentifiers() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(manifest.contains("\"com.justspeaktoit.mac.appstore\""))
        XCTAssertTrue(manifest.contains("\"com.justspeaktoit.mac\""))
        XCTAssertTrue(manifest.contains("bundleId: macBundleIdentifier"))
        XCTAssertTrue(manifest.contains("PRODUCT_BUNDLE_IDENTIFIER\": .string(macBundleIdentifier)"))
    }

    func testMacAppStoreWorkflow_exportsTheAppStoreIdentifier() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-appstore.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(workflow.contains("BUNDLE_ID: com.justspeaktoit.mac.appstore"))
        XCTAssertTrue(workflow.contains("<key>com.justspeaktoit.mac.appstore</key>"))
        XCTAssertFalse(workflow.contains("<key>com.justspeaktoit.mac</key>"))
        XCTAssertTrue(workflow.contains("APPLE_TEAM_ID.$BUNDLE_ID"))
        XCTAssertTrue(workflow.contains("com.apple.application-identifier"))
        XCTAssertTrue(workflow.contains("com.apple.developer.icloud-container-identifiers"))
        XCTAssertTrue(workflow.contains("iCloud.com.justspeaktoit"))
        XCTAssertTrue(workflow.contains("$0 == \"iCloud.com.justspeaktoit\""))
        XCTAssertFalse(workflow.contains("grep -Fq \"iCloud.com.justspeaktoit\""))
        XCTAssertFalse(workflow.contains("Entitlements.application-identifier"))
    }

    func testDirectMacRelease_runsKeychainTestsBeforeInstallingSigningKeychain() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-mac.yml"),
            encoding: .utf8
        )

        let testStep = try XCTUnwrap(workflow.range(of: "- name: Run Tests (Release Config)"))
        let signingStep = try XCTUnwrap(workflow.range(of: "- name: Import Code Signing Certificate"))

        XCTAssertLessThan(testStep.lowerBound, signingStep.lowerBound)
    }

    func testDirectMacRelease_retriesStaplingAcceptedNotarizationTickets() throws {
        // Per-variant packaging lives in the composite action the workflow calls
        // once per download (issue #774).
        let packaging = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/actions/package-mac-release/action.yml"),
            encoding: .utf8
        )
        let retryScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/retry-staple.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(packaging.contains("bash scripts/retry-staple.sh \"$APP_PATH\""))
        XCTAssertTrue(packaging.contains("bash scripts/retry-staple.sh \"$DMG_PATH\""))
        XCTAssertTrue(retryScript.contains("stapler staple"))
        XCTAssertTrue(retryScript.contains("stapler validate"))
        XCTAssertTrue(retryScript.contains("STAPLE_MAX_ATTEMPTS:-6"))
        XCTAssertTrue(retryScript.contains("[[ ! -e \"$ARTIFACT_PATH\" ]]"))
        XCTAssertTrue(retryScript.contains("STAPLE_MAX_ATTEMPTS must be a positive integer"))
        XCTAssertTrue(retryScript.contains("RETRY_DELAY > 300"))
    }

    func testPlatformAppTargets_doNotCompileTheOtherPlatformsUI() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )
        let macTarget = try targetBlock(named: "SpeakApp", in: manifest)
        let iosTarget = try targetBlock(named: "SpeakiOS", in: manifest)
        let macDependencies = try dependencyBlock(named: "macAppDependencies", in: manifest)
        let iosDependencies = try dependencyBlock(named: "iosAppDependencies", in: manifest)

        XCTAssertTrue(macTarget.contains("sources: [\"Sources/SpeakApp/**\"]"))
        XCTAssertTrue(macTarget.contains("dependencies: macAppDependencies"))
        XCTAssertFalse(macTarget.contains("SpeakiOSApp"))
        XCTAssertFalse(macDependencies.contains("SpeakiOSLib"))
        XCTAssertFalse(macDependencies.contains("JustSpeakToItWidgetExtension"))
        XCTAssertFalse(macDependencies.contains("JustSpeakKeyboard"))

        XCTAssertTrue(iosTarget.contains("sources: [\"SpeakiOSApp/**\"]"))
        XCTAssertTrue(iosTarget.contains("dependencies: iosAppDependencies"))
        XCTAssertTrue(iosDependencies.contains(".package(product: \"SpeakiOSLib\")"))
        XCTAssertTrue(
            iosDependencies.contains(
                "iosAppDependencies.append(.target(name: \"JustSpeakKeyboard\"))"
            )
        )
        XCTAssertFalse(iosTarget.contains("Sources/SpeakApp"))
        XCTAssertFalse(iosDependencies.contains("SpeakHotKeys"))
        XCTAssertFalse(iosDependencies.contains("Sparkle"))
    }

    func testIOSKeyboardTargetUsesPublicExtensionConfiguration() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )
        let keyboardTarget = try targetBlock(named: "JustSpeakKeyboard", in: manifest)
        let infoPlist = try String(
            contentsOf: repositoryRoot.appendingPathComponent("JustSpeakKeyboard/Info.plist"),
            encoding: .utf8
        )

        XCTAssertTrue(keyboardTarget.contains("bundleId: \"com.justspeaktoit.ios.keyboard\""))
        XCTAssertTrue(keyboardTarget.contains("product: .appExtension"))
        XCTAssertTrue(keyboardTarget.contains("settings: .settings(base: iosKeyboardSettings)"))
        XCTAssertTrue(manifest.contains("\"APPLICATION_EXTENSION_API_ONLY\": \"YES\""))
        XCTAssertTrue(infoPlist.contains("com.apple.keyboard-service"))
        XCTAssertTrue(infoPlist.contains("RequestsOpenAccess"))
        XCTAssertTrue(infoPlist.contains("$(PRODUCT_MODULE_NAME).KeyboardViewController"))
    }

    func testIOSKeyboardBuild_hasIndependentDirectCapturePolicy() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )
        let featureFlags = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SpeakiOSApp/FeatureFlags.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SpeakiOSApp/SpeakiOSApp.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/SpeakiOS/Views/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains("environment[\"TUIST_IOS_KEYBOARD\"] ?? \"\""))
        XCTAssertTrue(manifest.contains("let isIOSKeyboardEnabled = [\"1\", \"true\", \"yes\"]"))
        XCTAssertTrue(manifest.contains("if isIOSKeyboardEnabled {"))
        XCTAssertTrue(manifest.contains("projectTargets.append(keyboardTarget)"))
        XCTAssertTrue(manifest.contains("iosActiveCompilationConditions.append(\"IOS_KEYBOARD_FEATURE\")"))
        XCTAssertTrue(manifest.contains("environment[\"TUIST_IOS_KEYBOARD_DIRECT_CAPTURE\"] ?? \"\""))
        XCTAssertTrue(manifest.contains("IOS_KEYBOARD_DIRECT_CAPTURE"))
        XCTAssertTrue(manifest.contains("let iosKeyboardInfoPlist: InfoPlist = isIOSKeyboardDirectCaptureEnabled"))
        XCTAssertTrue(manifest.contains("? .file(path: \"JustSpeakKeyboard/Info.plist\")"))
        XCTAssertTrue(manifest.contains("infoPlist: iosKeyboardInfoPlist"))
        XCTAssertTrue(manifest.contains("settings: .settings(base: iosTestSettings)"))
        XCTAssertTrue(
            manifest.contains(
                "iosTestResourceElements.append(\"JustSpeakKeyboard/JustSpeakKeyboard.entitlements\")"
            )
        )
        XCTAssertTrue(featureFlags.contains("#if IOS_KEYBOARD_FEATURE"))
        XCTAssertTrue(featureFlags.contains("static var iOSKeyboardEnabled: Bool"))
        XCTAssertTrue(featureFlags.contains("static var iOSKeyboardDirectCaptureEnabled: Bool"))
        XCTAssertTrue(app.contains("guard FeatureFlags.iOSKeyboardEnabled else"))
        XCTAssertTrue(app.contains("KeyboardInstantDictationStore.shared.setEnabled(false)"))
        XCTAssertTrue(settings.contains("if iOSKeyboardEnabled"))
        XCTAssertTrue(settings.contains("KeyboardDictationPreferencesStore.shared.mirrorAppPreference"))
    }

    func testWatchAppBuildFeature_isOffByDefault() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )
        let featureFlags = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SpeakiOSApp/FeatureFlags.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SpeakiOSApp/SpeakiOSApp.swift"),
            encoding: .utf8
        )
        let releaseWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-ios.yml"),
            encoding: .utf8
        )
        let watchTarget = try targetBlock(named: "JustSpeakWatchApp", in: manifest)

        XCTAssertTrue(manifest.contains("environment[\"TUIST_WATCH_APP\"] ?? \"\""))
        XCTAssertTrue(manifest.contains("let isWatchAppEnabled = [\"1\", \"true\", \"yes\"]"))
        XCTAssertTrue(manifest.contains("if isWatchAppEnabled {"))
        XCTAssertTrue(manifest.contains("iosActiveCompilationConditions.append(\"WATCH_APP_FEATURE\")"))
        XCTAssertTrue(manifest.contains("projectTargets.append(watchAppTarget)"))
        XCTAssertTrue(featureFlags.contains("#if WATCH_APP_FEATURE"))
        XCTAssertTrue(featureFlags.contains("static var watchCaptureEnabled: Bool"))
        XCTAssertTrue(app.contains("if FeatureFlags.watchCaptureEnabled {"))

        // The watch app is a separate bundle id that still needs provisioning,
        // so release signing must not pick it up yet.
        XCTAssertFalse(releaseWorkflow.contains("TUIST_WATCH_APP"))
        XCTAssertTrue(watchTarget.contains("bundleId: \"com.justspeaktoit.ios.watchkitapp\""))
        XCTAssertTrue(watchTarget.contains("\"WKCompanionAppBundleIdentifier\": \"com.justspeaktoit.ios\""))
        XCTAssertTrue(watchTarget.contains("\"Sources/SpeakCore/WatchCaptureProtocol.swift\""))
    }

    func testWatchComplication_shipsOnlyWithTheWatchAppFeatureFlag() throws {
        let root = repositoryRoot
        let manifest = try String(contentsOf: root.appendingPathComponent("Project.swift"), encoding: .utf8)
        let releaseWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release-ios.yml"),
            encoding: .utf8
        )
        let entitlements = try String(
            contentsOf: root.appendingPathComponent("JustSpeakWatchWidget/JustSpeakWatchWidget.entitlements"),
            encoding: .utf8
        )
        let widgetTarget = try targetBlock(named: "JustSpeakWatchWidgetExtension", in: manifest)
        let watchTarget = try targetBlock(named: "JustSpeakWatchApp", in: manifest)

        // The complication rides on the watch app's flag: it is embedded in
        // the watch app and needs its own provisioning before release signing.
        XCTAssertTrue(manifest.contains("projectTargets.append(watchWidgetTarget)"))
        XCTAssertTrue(manifest.contains("environment[\"TUIST_WATCH_PROFILE_NAME\"]"))
        XCTAssertTrue(manifest.contains("environment[\"TUIST_WATCH_WIDGET_PROFILE_NAME\"]"))
        XCTAssertFalse(manifest.contains("environment[\"WATCH_PROFILE_NAME\"]"))
        XCTAssertFalse(manifest.contains("environment[\"WATCH_WIDGET_PROFILE_NAME\"]"))
        XCTAssertFalse(releaseWorkflow.contains("JustSpeakWatchWidget"))
        XCTAssertTrue(widgetTarget.contains("bundleId: \"com.justspeaktoit.ios.watchkitapp.complication\""))
        XCTAssertTrue(widgetTarget.contains("product: .appExtension"))
        XCTAssertTrue(watchTarget.contains(".target(name: \"JustSpeakWatchWidgetExtension\")"))
        // Both watch targets compile the shared intent and read the same
        // App Group container.
        for target in [widgetTarget, watchTarget] {
            XCTAssertTrue(target.contains("\"JustSpeakWatchShared/**\""))
            XCTAssertTrue(target.contains("\"Sources/SpeakCore/WatchSharedContainer.swift\""))
        }
        XCTAssertTrue(manifest.contains("\"$(inherited) WATCH_WIDGET_EXTENSION\""))
        XCTAssertTrue(entitlements.contains("<string>group.com.justspeaktoit.watch</string>"))
    }

    func testWatchComplication_usesSystemRecordingIntentWithAnOlderOSFallback() throws {
        let root = repositoryRoot
        let intent = try String(
            contentsOf: root.appendingPathComponent("JustSpeakWatchShared/StartWatchRecordingIntent.swift"),
            encoding: .utf8
        )
        let actionButton = try String(
            contentsOf: root.appendingPathComponent("JustSpeakWatchWidget/WatchRecordingActionButton.swift"),
            encoding: .utf8
        )
        let contentView = try String(
            contentsOf: root.appendingPathComponent("JustSpeakWatch/WatchContentView.swift"),
            encoding: .utf8
        )
        let watchApp = try String(
            contentsOf: root.appendingPathComponent("JustSpeakWatch/JustSpeakWatchApp.swift"),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: root.appendingPathComponent("JustSpeakWatch/WatchRecordingCoordinator.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(intent.contains("@available(watchOS 11.0, *)"))
        XCTAssertTrue(intent.contains("struct StartWatchRecordingIntent: AudioRecordingIntent"))
        XCTAssertTrue(intent.contains("struct OpenWatchRecordingIntent: AppIntent"))
        XCTAssertTrue(intent.contains("static var openAppWhenRun: Bool { false }"))
        XCTAssertTrue(intent.contains("static var openAppWhenRun: Bool { true }"))
        XCTAssertTrue(actionButton.contains("if #available(watchOS 11.0, *)"))
        XCTAssertTrue(actionButton.contains("Button(intent: StartWatchRecordingIntent()"))
        XCTAssertTrue(actionButton.contains("Button(intent: OpenWatchRecordingIntent()"))
        XCTAssertTrue(actionButton.contains(".accessibilityLabel(Text(self.state.recordingActionLabel))"))
        XCTAssertTrue(actionButton.contains(".accessibilityHint(Text(self.state.recordingActionHint))"))
        XCTAssertTrue(contentView.contains("WatchRecordingCoordinator.shared.toggleRecording()"))
        XCTAssertFalse(contentView.contains("recorder.toggle(store:"))
        XCTAssertTrue(coordinator.contains("await self.recorder.toggle()"))
        XCTAssertFalse(coordinator.contains("toggle(store:"))
        XCTAssertTrue(watchApp.contains(".task {"))
        XCTAssertTrue(watchApp.contains("performPendingWatchFaceRequest()"))
        let recovery = try XCTUnwrap(watchApp.range(of: "await recorder.recoverInterruptedCapture()"))
        let pending = try XCTUnwrap(
            watchApp.range(of: "await WatchRecordingCoordinator.shared.performPendingWatchFaceRequest()")
        )
        XCTAssertLessThan(recovery.lowerBound, pending.lowerBound)
    }

    func testWatchComplication_publishesEveryRecorderAndQueueTransition() throws {
        let root = repositoryRoot
        let recorder = try String(
            contentsOf: root.appendingPathComponent("JustSpeakWatch/WatchAudioRecorder.swift"),
            encoding: .utf8
        )
        let store = try String(
            contentsOf: root.appendingPathComponent("JustSpeakWatch/WatchCaptureStore.swift"),
            encoding: .utf8
        )
        let publisher = try String(
            contentsOf: root.appendingPathComponent("JustSpeakWatch/WatchComplicationPublisher.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(recorder.contains("didSet"))
        XCTAssertTrue(recorder.contains("WatchComplicationPublisher.shared.update("))
        XCTAssertEqual(recorder.components(separatedBy: "store.enqueue(").count - 1, 1)
        XCTAssertTrue(store.contains("WatchComplicationPublisher.shared.update(captures: captures)"))
        XCTAssertTrue(publisher.contains("WidgetCenter.shared.reloadAllTimelines()"))
        XCTAssertTrue(publisher.contains("latestFailureMessage"))
        XCTAssertTrue(publisher.contains("recordingStartedAt"))
        XCTAssertTrue(publisher.contains("expiresAt"))
    }

    func testIOSKeyboardUsesInstantSessionLivePreviewAndRetainsHistory() throws {
        // Keyboard v2 splits the extension into controller + model + view +
        // engine + handoff files; the fallback handoff invariants from v1 must
        // survive in the split sources.
        let controller = try String(
            contentsOf: repositoryRoot.appendingPathComponent("JustSpeakKeyboard/KeyboardViewController.swift"),
            encoding: .utf8
        )
        let handoff = try String(
            contentsOf: repositoryRoot.appendingPathComponent("JustSpeakKeyboard/KeyboardHandoffController.swift"),
            encoding: .utf8
        )
        let rootView = try String(
            contentsOf: repositoryRoot.appendingPathComponent("JustSpeakKeyboard/KeyboardRootView.swift"),
            encoding: .utf8
        )
        let instantCoordinator = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SpeakiOS/Services/KeyboardInstantDictationCoordinator.swift"
            ),
            encoding: .utf8
        )
        let engine = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "JustSpeakKeyboard/KeyboardDictationEngine.swift"
            ),
            encoding: .utf8
        )

        for source in [controller, handoff, rootView] {
            XCTAssertFalse(source.contains("extensionContext.open"))
        }
        XCTAssertTrue(handoff.contains("guard isInstantReady, let currentDocumentIdentifier"))
        XCTAssertTrue(handoff.contains("KeyboardHandoffSignal.postRequestChanged"))
        XCTAssertTrue(rootView.contains("Open Just Speak once"))
        XCTAssertTrue(rootView.contains("keyboardLiveTranscript"))
        XCTAssertFalse(rootView.contains("Results are deleted after insertion"))
        XCTAssertTrue(instantCoordinator.contains("input.installTap"))
        XCTAssertTrue(engine.contains("input.installTap"))
        XCTAssertTrue(engine.contains("try session.setCategory(.record"))
        XCTAssertTrue(instantCoordinator.contains("requiresLiveActivity: false"))
        XCTAssertTrue(instantCoordinator.contains("updateInterim"))
        XCTAssertFalse(instantCoordinator.contains(".write("))
        XCTAssertFalse(instantCoordinator.contains(".upload("))
        XCTAssertTrue(instantCoordinator.contains("saveToHistory: false"))
        XCTAssertTrue(instantCoordinator.contains("saveToHistory(transcript, result: result)"))
        XCTAssertTrue(instantCoordinator.contains("saveToHistory(result.text, result: result)"))
        XCTAssertTrue(instantCoordinator.contains("iOSHistoryManager.shared.recordTranscription"))
    }

    // swiftlint:disable:next function_body_length
    func testIOSReleaseWorkflowSignsAndValidatesKeyboardExtension() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-ios.yml"),
            encoding: .utf8
        )
        let autoRelease = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/auto-release.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(workflow.contains("IOS_KEYBOARD_APPSTORE_PROFILE"))
        XCTAssertTrue(workflow.contains("ios-keyboard-appstore.provisionprofile"))
        XCTAssertTrue(workflow.contains("com.justspeaktoit.ios.keyboard"))
        XCTAssertTrue(workflow.contains("--capability APP_GROUPS"))
        XCTAssertFalse(workflow.contains("--recreate"))
        XCTAssertTrue(workflow.contains("Keyboard provisioning profile does not authorize group.com.justspeaktoit.ios"))
        XCTAssertTrue(workflow.contains("ios-keyboard-appstore.plist"))
        XCTAssertTrue(workflow.contains("plutil -extract Entitlements xml1"))
        XCTAssertTrue(workflow.contains("<string>group.com.justspeaktoit.ios</string>"))
        XCTAssertFalse(workflow.contains("Entitlements.com.apple.security.application-groups.0"))
        XCTAssertFalse(workflow.contains("KEYBOARD_PROFILE_UUID_PLACEHOLDER"))
        XCTAssertTrue(
            workflow.contains(
                "Add :provisioningProfiles:com.justspeaktoit.ios.keyboard string $KEYBOARD_PROFILE_UUID"
            )
        )
        XCTAssertTrue(workflow.contains("JustSpeakKeyboard.appex"))
        XCTAssertTrue(workflow.contains("keyboard-entitlements.plist"))
        XCTAssertTrue(workflow.contains("APP_ICLOUD_CONTAINER"))
        XCTAssertTrue(workflow.contains("iCloud container mismatch"))
        XCTAssertTrue(workflow.contains("iCloud.com.justspeaktoit.ios"))
        XCTAssertTrue(workflow.contains("TUIST_IOS_KEYBOARD: ${{ inputs.include_keyboard && '1' || '0' }}"))
        XCTAssertTrue(
            workflow.contains(
                "TUIST_IOS_KEYBOARD_DIRECT_CAPTURE: ${{ inputs.include_keyboard && inputs.enable_direct_capture"
            )
        )
        XCTAssertTrue(workflow.contains("Keyboard feature is off, but JustSpeakKeyboard.appex was embedded"))
        XCTAssertTrue(workflow.contains("Handoff-only keyboard unexpectedly declares $usage_key"))
        XCTAssertTrue(workflow.contains("Direct-capture keyboard is missing $usage_key"))
        let keyboardInputStart = try XCTUnwrap(workflow.range(of: "      include_keyboard:\n")?.lowerBound)
        let directInputStart = try XCTUnwrap(workflow.range(of: "      enable_direct_capture:\n")?.lowerBound)
        let environmentStart = try XCTUnwrap(workflow.range(of: "\nenv:\n")?.lowerBound)
        let keyboardInput = workflow[keyboardInputStart..<directInputStart]
        XCTAssertTrue(keyboardInput.contains("default: true"))
        XCTAssertTrue(keyboardInput.contains("type: boolean"))
        let directInput = workflow[directInputStart..<environmentStart]
        XCTAssertTrue(directInput.contains("default: false"))
        XCTAssertTrue(autoRelease.contains("-f include_keyboard=true"))
        XCTAssertTrue(autoRelease.contains("-f enable_direct_capture=false"))

        let profileBootstrap = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/create-ios-app-store-profile.rb"),
            encoding: .utf8
        )
        XCTAssertTrue(profileBootstrap.contains("@client.post(\"/v1/bundleIds\""))
        XCTAssertTrue(profileBootstrap.contains("/bundleIdCapabilities\""))
        XCTAssertFalse(profileBootstrap.contains("/bundleIdCapabilities?limit="))
        XCTAssertTrue(profileBootstrap.contains("@client.post(\"/v1/bundleIdCapabilities\""))
        XCTAssertTrue(profileBootstrap.contains("capabilityType: capability_type"))
        XCTAssertFalse(profileBootstrap.contains("method: Net::HTTP::Delete"))
        XCTAssertFalse(profileBootstrap.contains("profiles.each do |stale_profile|"))
    }

    func testSpeakCLIBuildScript_buildsPerArchAndValidatesTheUniversalBinary() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/build-speak-cli.sh"),
            encoding: .utf8
        )

        // A combined dual-arch swift build fails to plan the SwiftFormat
        // plugin dependency (issue #759); the slices must be built separately
        // and joined with lipo, and the result must be verified universal.
        XCTAssertFalse(script.contains("--arch arm64 --arch x86_64"))
        XCTAssertTrue(script.contains("swift build --product speak --configuration release --arch arm64"))
        XCTAssertTrue(script.contains("swift build --product speak --configuration release --arch x86_64"))
        XCTAssertTrue(script.contains("lipo -create"))
        XCTAssertTrue(script.contains("lipo -archs"))
        XCTAssertTrue(script.contains("speak binary is missing"))
        // The arm64 primary download embeds an arm64-only CLI, and a slice the
        // variant does not promise fails the build (issue #774).
        XCTAssertTrue(script.contains("VARIANT=\"${3:-universal}\""))
        XCTAssertTrue(script.contains("arm64) REQUIRED_ARCHS=\"arm64\""))
        XCTAssertTrue(script.contains("universal) REQUIRED_ARCHS=\"arm64 x86_64\""))
        XCTAssertTrue(script.contains("speak binary must not contain"))
    }

    // MARK: - arm64 primary + universal legacy downloads (issue #774)

    func testDirectMacRelease_packagesTheArm64PrimaryAndUniversalLegacyVariants() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-mac.yml"),
            encoding: .utf8
        )
        let packaging = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/actions/package-mac-release/action.yml"),
            encoding: .utf8
        )

        XCTAssertEqual(workflow.components(separatedBy: "uses: ./.github/actions/package-mac-release").count - 1, 2)
        XCTAssertTrue(workflow.contains("variant: arm64"))
        XCTAssertTrue(workflow.contains("variant: universal"))
        XCTAssertTrue(packaging.contains("arm64) ARCHS=\"arm64\""))
        XCTAssertTrue(packaging.contains("universal) ARCHS=\"arm64 x86_64\""))
        XCTAssertTrue(packaging.contains("ARCHS=\"${{ steps.paths.outputs.archs }}\""))
        XCTAssertTrue(packaging.contains("ONLY_ACTIVE_ARCH=NO"))
        XCTAssertTrue(packaging.contains("dmg-path=$WORK/$PRODUCT_NAME-${{ inputs.variant }}.dmg"))
        let embedCLI = "./scripts/build-speak-cli.sh \"$APP_PATH\" \"Developer ID Application\" "
            + "\"${{ inputs.variant }}\""
        XCTAssertTrue(packaging.contains(embedCLI))
        // The two builds must not share scratch space.
        XCTAssertTrue(packaging.contains("RUNNER_TEMP=\"${{ steps.paths.outputs.work }}\" ./scripts/create-dmg.sh"))
    }

    func testDirectMacRelease_verifiesArchitectureGatekeeperAndRecordsSizes() throws {
        let packaging = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/actions/package-mac-release/action.yml"),
            encoding: .utf8
        )
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-mac.yml"),
            encoding: .utf8
        )
        let architectureScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verify-architecture.sh"),
            encoding: .utf8
        )
        let sizeScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/record-release-size.sh"),
            encoding: .utf8
        )

        let verifyArchitecture = "./scripts/verify-architecture.sh \"${{ steps.paths.outputs.app-path }}\" "
            + "\"${{ inputs.variant }}\""
        XCTAssertTrue(packaging.contains(verifyArchitecture))
        XCTAssertTrue(packaging.contains("spctl --assess --type execute"))
        XCTAssertTrue(packaging.contains("./scripts/record-release-size.sh"))
        XCTAssertTrue(workflow.contains("GITHUB_STEP_SUMMARY"))

        XCTAssertTrue(architectureScript.contains("lipo -archs"))
        XCTAssertTrue(architectureScript.contains("Contents/MacOS/JustSpeakToIt"))
        XCTAssertTrue(architectureScript.contains("Contents/MacOS/speak"))
        XCTAssertTrue(architectureScript.contains("must contain exactly"))
        XCTAssertTrue(sizeScript.contains("GITHUB_STEP_SUMMARY"))
        XCTAssertTrue(sizeScript.contains("du -sk"))
    }

    func testDirectMacRelease_publishesOneFeedAndOneCaskArchitecturePerDownload() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-mac.yml"),
            encoding: .utf8
        )
        let appcastScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/generate-appcast.sh"),
            encoding: .utf8
        )

        // Legacy feed keeps its name and serves the universal DMG; the arm64 feed serves the arm64 DMG.
        let continuation = " \\\n            "
        let legacyFeed = [
            "\"$LEGACY_DMG_PATH\"", "\"$SPARKLE_PRIVATE_KEY\"", "\"$RUNNER_TEMP/release-notes.html\"",
            "\"https://justspeaktoit.com/appcast.xml\" > \"$RUNNER_TEMP/appcast.xml\""
        ].joined(separator: continuation)
        let arm64Feed = [
            "\"$DMG_PATH\"", "\"$SPARKLE_PRIVATE_KEY\"", "\"$RUNNER_TEMP/release-notes.html\"",
            "\"https://justspeaktoit.com/appcast-arm64.xml\" > \"$RUNNER_TEMP/appcast-arm64.xml\""
        ].joined(separator: continuation)
        XCTAssertTrue(workflow.contains(legacyFeed))
        XCTAssertTrue(workflow.contains(arm64Feed))
        XCTAssertTrue(workflow.contains("! grep -q \"$(basename \"$DMG_PATH\")\" \"$RUNNER_TEMP/appcast.xml\""))
        XCTAssertTrue(appcastScript.contains("FEED_URL=\"${6:-https://justspeaktoit.com/appcast.xml}\""))
        XCTAssertTrue(appcastScript.contains("<link>${FEED_URL}</link>"))

        // Both downloads and both feeds are release assets.
        let releaseAssets = [
            "${{ env.DMG_PATH }}", "${{ env.LEGACY_DMG_PATH }}",
            "${{ env.APPCAST_PATH }}", "${{ env.ARM64_APPCAST_PATH }}"
        ].joined(separator: "\n            ")
        XCTAssertTrue(workflow.contains(releaseAssets))

    }

    func testDirectMacRelease_publishesCLIAssetsAndDelegatesTheTap() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-mac.yml"),
            encoding: .utf8
        )
        let appcastScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/generate-appcast.sh"),
            encoding: .utf8
        )

        // The standalone CLI assets ride along when their optional step succeeded (issue #775).
        let cliAssets = [
            "${{ env.CLI_ARM64_ZIP }}", "${{ env.CLI_X86_64_ZIP }}",
            "${{ env.CLI_MANIFEST }}", "${{ env.CLI_MANIFEST_SIG }}"
        ].joined(separator: "\n            ")
        XCTAssertTrue(workflow.contains(cliAssets))

        // The tap is written by one script the workflow delegates to: the cask
        // hands each architecture its own download and checksum, and depends
        // on the speak formula instead of linking the binary inside the bundle.
        let tapScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/update-homebrew-tap.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(workflow.contains(
            "./scripts/update-homebrew-tap.sh \"$VERSION\" \"$ARM64_SHA256\" \"$UNIVERSAL_SHA256\""
        ))
        XCTAssertTrue(tapScript.contains("arch arm: \"arm64\", intel: \"universal\""))
        XCTAssertTrue(tapScript.contains("sha256 arm:   \"$ARM64_SHA256\",\n         intel: \"$UNIVERSAL_SHA256\""))
        XCTAssertTrue(tapScript.contains(
            "RELEASE_URL=\"https://github.com/crmitchelmore/justspeaktoit/releases/download/mac-v#{version}\""
        ))
        XCTAssertTrue(tapScript.contains("url \"${RELEASE_URL}/JustSpeakToIt-#{arch}.dmg\""))
        XCTAssertTrue(tapScript.contains("depends_on formula: \"crmitchelmore/justspeaktoit/speak\""))
        XCTAssertFalse(tapScript.contains("binary \"#{appdir}"))
        XCTAssertTrue(tapScript.contains("speak-#{version}-arm64.zip"))
        XCTAssertTrue(tapScript.contains("speak-#{version}-x86_64.zip"))

        // The retry workflow reads the DMG digests back out of that two-line
        // cask by label, not by layout, and refuses to proceed without them.
        let retryWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/publish-speak-cli.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(retryWorkflow.contains("grep -oE 'arm: *\"[0-9a-f]{64}\"'"))
        XCTAssertTrue(retryWorkflow.contains("grep -oE 'intel: *\"[0-9a-f]{64}\"'"))
        XCTAssertTrue(retryWorkflow.contains("Could not read the DMG digests"))
        // It builds the CLI from the tag but runs the pipeline files from
        // main, fetched into the remote-tracking ref it then checks out from.
        XCTAssertTrue(retryWorkflow.contains("ref: refs/tags/mac-v${{ github.event.inputs.version }}"))
        XCTAssertTrue(retryWorkflow.contains(
            "git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main"
        ))
        XCTAssertTrue(retryWorkflow.contains("git checkout origin/main -- \\\n            scripts/"))
        XCTAssertTrue(retryWorkflow.contains("            .github/actions/publish-speak-cli\n"))

        // Signing tools never arrive through an unverified download while the
        // private key is on disk.
        let signScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/sparkle-sign-file.sh"),
            encoding: .utf8
        )
        XCTAssertFalse(signScript.contains("curl"))
        XCTAssertTrue(appcastScript.contains("SPARKLE_TOOLS_SHA256="))
        XCTAssertTrue(appcastScript.contains("curl --fail"))
    }

    func testLandingPageRedirects_routeBothFeedsAndDownloadsAheadOfTheIndexRewrite() throws {
        let redirects = try String(
            contentsOf: repositoryRoot.appendingPathComponent("landing-page/_redirects"),
            encoding: .utf8
        )
        let lines = redirects.components(separatedBy: "\n")
        func index(of prefix: String) -> Int? { lines.firstIndex { $0.hasPrefix(prefix) } }

        let legacyFeed = try XCTUnwrap(index(of: "/appcast.xml "))
        let arm64Feed = try XCTUnwrap(index(of: "/appcast-arm64.xml "))
        let appleSiliconDownload = try XCTUnwrap(index(of: "/download/mac "))
        let intelDownload = try XCTUnwrap(index(of: "/download/mac-intel "))
        let indexRewrite = try XCTUnwrap(index(of: "/index.html "))

        XCTAssertTrue(lines[arm64Feed].contains("releases/latest/download/appcast-arm64.xml"))
        XCTAssertTrue(lines[appleSiliconDownload].contains("releases/latest/download/JustSpeakToIt-arm64.dmg"))
        XCTAssertTrue(lines[intelDownload].contains("releases/latest/download/JustSpeakToIt-universal.dmg"))
        for rule in [legacyFeed, arm64Feed, appleSiliconDownload, intelDownload] {
            XCTAssertLessThan(rule, indexRewrite, "exact redirects must precede the index rewrite")
        }
    }

    func testIOSReleaseWorkflowRequiresAnExplicitSemanticVersion() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-ios.yml"),
            encoding: .utf8
        )

        let versionInputStart = try XCTUnwrap(workflow.range(of: "      version:\n")?.lowerBound)
        let buildInputStart = try XCTUnwrap(workflow.range(of: "      build_number:\n")?.lowerBound)
        let versionInput = workflow[versionInputStart..<buildInputStart]
        XCTAssertTrue(versionInput.contains("required: true"))
        XCTAssertTrue(versionInput.contains("type: string"))

        let validationStart = try XCTUnwrap(workflow.range(of: "      - name: Determine Version\n")?.lowerBound)
        let buildNumberStart = try XCTUnwrap(workflow.range(of: "      - name: Determine Build Number\n")?.lowerBound)
        let validation = workflow[validationStart..<buildNumberStart]
        XCTAssertTrue(validation.contains("INPUT_VERSION: ${{ inputs.version }}"))
        XCTAssertTrue(validation.contains("iOS release version is required"))
        XCTAssertTrue(validation.contains("VERSION is not authoritative for TestFlight"))
        XCTAssertTrue(validation.contains("must be semantic version text"))

        let patternPrefix = "VERSION_PATTERN='"
        let patternStart = try XCTUnwrap(validation.range(of: patternPrefix)?.upperBound)
        let patternEnd = try XCTUnwrap(validation[patternStart...].firstIndex(of: "'"))
        let pattern = String(validation[patternStart..<patternEnd])
        let regex = try NSRegularExpression(pattern: pattern)
        func isAccepted(_ value: String) -> Bool {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.firstMatch(in: value, range: range)?.range == range
        }
        XCTAssertTrue(isAccepted("2.29.2"))
        XCTAssertTrue(isAccepted("0.0.0"))
        XCTAssertFalse(isAccepted(""))
        XCTAssertFalse(isAccepted("01.2.3"))
        XCTAssertFalse(isAccepted("2.00.3"))
        XCTAssertFalse(isAccepted("v2.29.2"))
        XCTAssertFalse(isAccepted("2.29"))
        XCTAssertFalse(workflow.contains("leave empty to use VERSION file"))
        XCTAssertFalse(workflow.contains("VERSION=$(cat VERSION)"))
    }

    func testIOSApp_declaresRequiredBackgroundModes() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Project.swift"),
            encoding: .utf8
        )
        let iosTarget = try targetBlock(named: "SpeakiOS", in: manifest)

        XCTAssertTrue(iosTarget.contains("\"UIBackgroundModes\": [\"audio\", \"remote-notification\"]"))
    }
    // swiftlint:disable:next file_length
}
