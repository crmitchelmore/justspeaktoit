import AppKit
import SpeakCore
import SwiftUI
import XCTest

@testable import SpeakApp

/// Drives the real Transcription settings screen in a window, so the model
/// pickers mounted for the outgoing selection observe each change as they do
/// in the running app.
@MainActor
final class TranscriptionLocationPickerHostingTests: XCTestCase {
    func testSwitchingFromAppleSpeechToRemote_staysRemote() {
        let environment = WireUp.bootstrap(options: makeWireUpTestOptions())
        let settings = environment.settings
        settings.selectLocalTranscriptionSource(.apple)
        let window = host(environment)
        defer { window.close() }

        settings.selectTranscriptionLocation(.remote)
        pumpRunLoop()

        XCTAssertEqual(settings.transcriptionLocation, .remote)
        XCTAssertTrue(settings.isRemoteStreamingTranscriptionSelected)
        XCTAssertFalse(ModelCatalog.isOnDeviceLiveTranscriptionModel(settings.liveTranscriptionModel))
    }

    func testLocationRoundTrips_keepEachSelection() {
        let environment = WireUp.bootstrap(options: makeWireUpTestOptions())
        let settings = environment.settings
        let window = host(environment)
        defer { window.close() }

        for source in AppSettings.LocalTranscriptionSource.allCases {
            settings.selectLocalTranscriptionSource(source)
            pumpRunLoop()
            XCTAssertEqual(settings.transcriptionLocation, .local, "\(source)")
            XCTAssertEqual(settings.localTranscriptionSource, source)

            settings.selectTranscriptionLocation(.remote)
            pumpRunLoop()
            XCTAssertEqual(settings.transcriptionLocation, .remote, "leaving \(source)")

            settings.selectTranscriptionLocation(.local)
            pumpRunLoop()
            XCTAssertEqual(settings.transcriptionLocation, .local, "returning to \(source)")
            XCTAssertEqual(settings.localTranscriptionSource, source)
        }
    }

    private func host(_ environment: AppEnvironment) -> NSWindow {
        let view = SettingsView(tab: .transcription, sidebarSelection: .constant(.settings(.transcription)))
            .environmentObject(environment)
            .environmentObject(environment.settings)
            .environmentObject(environment.paidAccess)
            .environmentObject(environment.history)
            .environmentObject(environment.personalLexicon)
            .environmentObject(environment.audioDevices)
            .environmentObject(environment.tts)
            .environmentObject(environment.shortcuts)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1068, height: 851),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        pumpRunLoop()
        return window
    }

    /// Lets SwiftUI apply the update and run any deferred picker writes.
    private func pumpRunLoop() {
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
