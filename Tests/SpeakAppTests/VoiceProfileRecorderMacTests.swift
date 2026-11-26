import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

final class VoiceProfileRecorderMacTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-profile-recorder-mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    @MainActor
    func testVoiceProfileRecorder_CapsOverlongAutoStoppedBuffersOnly() {
        let slightlyLong = VoiceProfileMacTests.makeSpeechBuffer(duration: 30.04, sampleRate: 24_000, withPauses: true)
        let capped = VoiceProfileRecorder.cappedToMaximumDuration(slightlyLong)
        XCTAssertEqual(capped.sampleRate, 24_000)
        XCTAssertEqual(capped.durationSeconds, VoiceProfile.maximumClipDuration, accuracy: 0.001)
        XCTAssertTrue(VoiceProfileQualityGate().evaluate(capped).passed)

        let manualShort = VoiceProfileMacTests.makeSpeechBuffer(duration: 12.0, sampleRate: 24_000, withPauses: true)
        let untouched = VoiceProfileRecorder.cappedToMaximumDuration(manualShort)
        XCTAssertEqual(untouched.samples.count, manualShort.samples.count)
    }

    @MainActor
    func testVoiceProfileManager_HistoryTranscriptClearedWhenTrimmedPreservedWhenUntrimmed() throws {
        let storeRoot = VoiceProfileStore.defaultDirectory(in: temporaryRoot)
        let manager = VoiceProfileManager(store: VoiceProfileStore(directory: storeRoot))

        let shortURL = temporaryRoot.appendingPathComponent("short-history.wav")
        let shortAudio = VoiceProfileMacTests.makeSpeechBuffer(duration: 12.0, sampleRate: 24_000, withPauses: true)
        try VoiceProfileWAVCodec.encodeWAV(shortAudio, format: .pcm24k).write(to: shortURL)
        let shortItem = makeHistoryItem(
            raw: "Verbatim raw words.",
            processed: "Polished words.",
            duration: 12.0,
            audioFileURL: shortURL
        )
        let untrimmed = try manager.prepareClipFromHistory(shortItem)
        XCTAssertEqual(untrimmed.transcript, "Verbatim raw words.")

        let rate = 16_000
        let speech = VoiceProfileMacTests.makeSpeechBuffer(duration: 15.0, sampleRate: rate, withPauses: true).samples
        let paddedAudio = VoiceProfilePCMBuffer(
            samples: [Float](repeating: 0, count: rate * 10) + speech + [Float](repeating: 0, count: rate * 10),
            sampleRate: rate
        )
        let longURL = temporaryRoot.appendingPathComponent("long-history.wav")
        try VoiceProfileWAVCodec.encodeWAV(paddedAudio, format: .pcm16k).write(to: longURL)
        let longItem = makeHistoryItem(
            raw: "Entire 35 second transcript.",
            processed: nil,
            duration: 35.0,
            audioFileURL: longURL
        )
        let trimmed = try manager.prepareClipFromHistory(longItem)
        XCTAssertEqual(trimmed.transcript, "")
    }

    private func makeHistoryItem(
        raw: String?,
        processed: String?,
        duration: TimeInterval,
        audioFileURL: URL
    ) -> HistoryItem {
        HistoryItem(
            modelsUsed: [ModelCatalog.defaultBatchTranscriptionModel],
            rawTranscription: raw,
            postProcessedTranscription: processed,
            recordingDuration: duration,
            cost: nil,
            audioFileURL: audioFileURL,
            networkExchanges: [],
            events: [],
            phaseTimestamps: PhaseTimestamps(
                recordingStarted: nil,
                recordingEnded: nil,
                transcriptionStarted: nil,
                transcriptionEnded: nil,
                postProcessingStarted: nil,
                postProcessingEnded: nil,
                outputDelivered: nil
            ),
            trigger: HistoryTrigger(
                gesture: .singleTap,
                hotKeyDescription: "Fn",
                outputMethod: .accessibility,
                destinationApplication: "Notes"
            ),
            personalCorrections: nil,
            errors: []
        )
    }
}
