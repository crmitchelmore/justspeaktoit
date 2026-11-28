import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

final class DesktopNativeVoiceProfileTests: XCTestCase {
    func testGuidedRecording_UsesSyntheticPCMAndRetiresCaptureOnClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pcm = DesktopHostVoiceProfilesTests.makeSpeechBuffer(duration: 8, sampleRate: 16_000, withPauses: true)
        let effects = NativeTestEffects(profileSamples: pcm.samples.map { Int16(clamping: Int($0 * 32_768)) })
        let controller = try DesktopHostController<NativeTestPlatform>.consented(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let session = UUID().uuidString
        func send(_ operation: Int32, metadata: String = "", text: String = "") async throws {
            let message = try DesktopVoiceSourceMessage(action: 120, source: operation, text: text,
                record: session + metadata, path: "")
            guard case .profile(let command) = message else { return XCTFail("Expected profile command") }
            await controller.handleVoiceProfileCommand(command)
        }
        try await send(0)
        try await send(6)
        let firstSamples = await controller.voiceProfileDraft?.samples
        let retiredSamples = try XCTUnwrap(firstSamples)
        try await send(7)
        try await send(6)
        await controller.voiceProfileRecordingFailed(samples: retiredSamples, message: "Late first-take failure")
        let stillRecording = await controller.busy
        XCTAssertTrue(stillRecording)
        try await send(7)
        try await send(4, metadata: "\nconsent-v1\nGuided fixture\nen", text: "Edited script.")
        let profile = try XCTUnwrap(controller.voiceProfiles.listProfiles().first)
        XCTAssertEqual(profile.clips.first?.source, .recorded)
        XCTAssertEqual(profile.clips.first?.transcript, "Edited script.")
        try await send(0)
        try await send(6)
        try await send(5)
        let busy = await controller.busy
        XCTAssertFalse(busy)
        XCTAssertEqual(try controller.voiceProfiles.listProfiles().count, 1)
        let history = try await controller.store.records()
        XCTAssertTrue(history.isEmpty)
        await controller.close()
    }

    func testShutdownReportsProfileCaptureStillStopping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0)
        let effects = NativeTestEffects(profileSamples: [], profileStop: {
            _ = release.wait(timeout: .now() + 5)
        })
        let controller = try DesktopHostController<NativeTestPlatform>.consented(
            directory: root, effects: effects, shutdownGrace: .milliseconds(100))
        await controller.markReadyForSelfTest()
        let session = UUID().uuidString
        for operation: Int32 in [0, 6] {
            let message = try DesktopVoiceSourceMessage(action: 120, source: operation, text: "", record: session, path: "")
            guard case .profile(let command) = message else { return XCTFail("Expected profile command") }
            await controller.handleVoiceProfileCommand(command)
        }
        let report = await controller.close()
        release.signal()
        XCTAssertEqual(report.unfinishedOperations, 1)
    }

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

        func send(_ operation: Int32, text: String = "", metadata: String = "", reference: String = "") async throws {
            let message = try DesktopVoiceSourceMessage(action: 120, source: operation, text: text,
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

final class NativeProfileFixtureCapture: DesktopRecordingCapture {
    private let context: DesktopCaptureContext
    private let samples: [Int16]

    private let onStop: @Sendable () -> Void

    init(context: DesktopCaptureContext, samples: [Int16], onStop: @escaping @Sendable () -> Void) {
        self.onStop = onStop
        self.context = context
        self.samples = samples
    }

    func start() throws {
        samples.withUnsafeBufferPointer { buffer in
            if let start = buffer.baseAddress { context.receive(start, count: buffer.count) }
        }
    }

    func stop() throws { onStop() }
    func destroy() {}
}
