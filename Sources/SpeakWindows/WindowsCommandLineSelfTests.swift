import Foundation
import CWindowsSupport
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform

extension WindowsNative {
    /// Fresh synthetic leaves must name their token user as owner even when
    /// an elevated token's default owner is a group. Never repairs an existing path.
    static func createSyntheticDirectory(_ directory: URL) throws {
        try directory.path.withCString { path in
            try checked { jsti_private_directory_create(path, $0, $1) }
        }
    }
}

enum WindowsCommandLineSelfTests {
    static func handle(_ arguments: [String]) async throws -> Bool {
        if arguments.contains("--bundle-self-test") {
            try await WindowsBundleSelfTest.run()
            return true
        }
        if try await WindowsLocalSelfTest.handle(arguments) { return true }
        if arguments.contains("--self-test") {
            try await runSelfTest()
            return true
        }
        guard arguments.contains("--recording-feedback-self-test") else { return false }
        for profile in RecordingFeedbackProfile.allCases {
            let times = try await WindowsRecordingFeedbackLoader.checkNativeOutput(profile: profile)
            let milliseconds = times.map { String(format: "%.3f", $0 * 1_000) }.joined(separator: ", ")
            print("Recording feedback \(profile.rawValue) first-buffer queue admission (ms): \(milliseconds)")
        }
        print("Native Windows recording feedback queue test passed; this is not audible hardware latency.")
        return true
    }

    private static func runSelfTest() async throws {
        try await WindowsRecordingFeedbackSelfTest.validateBundledAssets()
        try WindowsNative.checked { jsti_native_self_test($0, $1) }
        try WindowsNative.checked { jsti_text_output_self_test($0, $1) }
        try WindowsNative.checked { jsti_clipboard_output_self_test($0, $1) }
        try await WindowsTextOutputSelfTest.run()
        try await WindowsHotKeySelfTest.run()
        try await WindowsHistoryRetrySelfTest.run()
        try await WindowsPostProcessingSelfTest.run()
        try await WindowsTroubleshootingSelfTest.run()
        try WindowsNative.storageMediaAndAutomationSelfTests()
        try await WindowsLocalSelfTest.run()
        guard !DesktopTranscription.batchModels.isEmpty else {
            throw WindowsNativeError(message: "No canonical desktop models available.")
        }
        print("Native Windows adapter and canonical model self-test passed.")
    }
}
