import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopHostCloudSharingWithdrawalTests: XCTestCase {
    func testWithdrawingTheTranscriptionProvider_StopsALiveDictationAndKeepsItsRecord() async throws {
        for owned in [false, true] {
            let fixture = AutoCleanHostFixture()
            try await fixture.prepare(owned: owned)
            await fixture.toggle()
            let before = await fixture.host.recording != nil
            let ownedBefore = await fixture.host.ownedDictation != nil
            XCTAssertTrue(before || ownedBefore, "owned: \(owned)")
            let provider = try XCTUnwrap(DesktopHostCloudSharing.transcription(model: fixture.model)?.provider.id)
            await fixture.host.withdrawCloudSharing(providerID: provider)
            // An owned capture retires on its own task.
            for _ in 0..<100 where await fixture.host.ownedDictation != nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            let after = await fixture.host.recording
            let ownedAfter = await fixture.host.ownedDictation
            XCTAssertNil(after, "owned: \(owned)")
            XCTAssertNil(ownedAfter, "owned: \(owned)")
            try await fixture.cleanup()
        }
    }

    func testWithdrawingWithKeepAudioOff_StillKeepsTheCapturedRecording() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        let configuration = try DesktopConfiguration(values: [
            "postRecordingTailDuration": AnyCodable(.int(0)),
            "keepAudioOnCancel": AnyCodable(.bool(false))
        ])
        try await fixture.host.saveConfiguration(configuration.entries)
        await fixture.toggle()
        let provider = try XCTUnwrap(DesktopHostCloudSharing.transcription(model: fixture.model)?.provider.id)
        await fixture.host.withdrawCloudSharing(providerID: provider)
        let saved = try await fixture.host.store.records()
        XCTAssertEqual(saved.count, 1)
        try await fixture.cleanup()
    }

    func testWithdrawingAnotherProvider_LeavesALiveDictationRunning() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        await fixture.toggle()
        let other = try XCTUnwrap(CloudSharingProviderCatalogue.all.first {
            $0.id != DesktopHostCloudSharing.transcription(model: fixture.model)?.provider.id
        })
        await fixture.host.withdrawCloudSharing(providerID: other.id)
        let still = await fixture.host.recording
        XCTAssertNotNil(still)
        try await fixture.cleanup()
    }
}
