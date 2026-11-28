import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopNativeVoiceProfileTests: XCTestCase {
    func testNativeEditor_SavesReviewedClipsAndRequiresDeletionReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<NativeTestPlatform>.consented(
            directory: root, effects: NativeTestEffects())
        let fixture = root.appendingPathComponent("synthetic.wav")
        let pcm = DesktopHostVoiceProfilesTests.makeSpeechBuffer(duration: 9, sampleRate: 16_000, withPauses: true)
        try VoiceProfileWAVCodec.encodeWAV(pcm, format: .pcm16k).write(to: fixture)
        let session = UUID().uuidString

        func send(_ op: Int32, text: String = "", metadata: String = "", reference: String = "") async throws {
            let message = try DesktopVoiceSourceMessage(action: 120, source: op, text: text,
                record: session + metadata, path: reference)
            guard case .profile(let command) = message else { return XCTFail("Expected voice profile command") }
            await controller.handleVoiceProfileCommand(command)
        }
        try await send(0, reference: fixture.path)
        try await send(3, text: "First synthetic clip.")
        try await send(0, reference: fixture.path)
        try FileManager.default.removeItem(at: fixture)
        try await send(4, text: "Edited clip.", metadata: "\nconsent-v1\nSynthetic voice\nen")
        let saved = try XCTUnwrap(controller.voiceProfiles.listProfiles().first)
        XCTAssertEqual(saved.clips.map(\.transcript), ["First synthetic clip.", "Edited clip."])
        XCTAssertTrue(saved.consent.isCurrent)
        let history = try await controller.store.records()
        XCTAssertTrue(history.isEmpty)
        try await send(0)
        try await send(9, reference: saved.id.uuidString)
        XCTAssertNotNil(try controller.voiceProfiles.profile(id: saved.id))
        try await send(8, reference: saved.id.uuidString)
        try await send(9, reference: saved.id.uuidString)
        XCTAssertTrue(try controller.voiceProfiles.listProfiles().isEmpty)
        await controller.close()
    }
}
