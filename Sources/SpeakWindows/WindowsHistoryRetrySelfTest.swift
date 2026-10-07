import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform

/// History Retry through the real controller with synthetic effects: no
/// microphone, credential, network, model download or speech runtime is used.
/// A retry runs with its recording's own model and language, never the
/// picker's, and keeps the recording's identity, audio and metadata. An
/// on-device model that cannot run is refused before anything is written, a
/// live-only or retired model keeps its guidance, and failed or silent
/// retries keep the audio and the record.
enum WindowsHistoryRetrySelfTest {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSTI history retry self-test \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = SyntheticEffects()
        let controller = try WindowsAppController(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let checks = RetryChecks(
            controller: controller, effects: effects, history: root.appendingPathComponent("History", isDirectory: true)
        )
        do {
            try await checks.run()
        } catch {
            await controller.close()
            throw error
        }
        await controller.close()
        print("History retry checks passed.")
    }
}

private struct RetryChecks {
    static let retired = "acme/retired-transcriber"
    let controller: WindowsAppController
    let effects: SyntheticEffects
    let history: URL

    func run() async throws {
        guard let onDevice = WindowsModels.local.first?.id,
              let batch = WindowsModels.all.firstIndex(where: { DesktopTranscription.provider(for: $0.id) != nil }),
              let live = WindowsModels.live.first(where: { DesktopTranscription.provider(for: $0.id) == nil })?.id
        else { throw retryFailure("the model catalogue has no on-device, batch and live-only model") }
        // The picker is on a remote batch model; every retry must use its recording's own.
        await controller.selectModel(batch)
        try await checkUnreadyOnDeviceModelIsRefused(onDevice, live: live)
        try await checkReadyOnDeviceRetryKeepsTheRecording(onDevice)
        try await checkFailedAndSilentRetriesKeepHistory(onDevice)
        try await checkLiveAndRetiredModelsKeepGuidance(live)
    }

    /// Nothing is downloaded in this fresh folder, whatever runtime the build
    /// carries, so the real readiness check refuses; so does a runtime that
    /// cannot start. Neither refusal writes or transcribes anything.
    private func checkUnreadyOnDeviceModelIsRefused(_ model: String, live: String) async throws {
        let record = try await seed(model, failure: "Transcription cancelled. Audio retained.")
        let before = try files(record)
        let arrivals = effects.transcription.arrivals
        let refusal = await controller.retryRefusal(for: model)
        let liveGuidance = await controller.retryRefusal(for: live)
        try require(refusal != nil && refusal != liveGuidance, "an on-device retry was not checked for readiness")
        await controller.retryHistory(record.id.uuidString)
        await controller.retryHistory(record.id.uuidString, onDeviceReadiness: { _ in
            "The on-device speech runtime could not start: synthetic failure."
        })
        let after = try files(record)
        try require(
            after == before && effects.transcription.arrivals == arrivals,
            "a refused on-device retry changed its recording or transcribed"
        )
    }

    /// The retry runs the recording's own on-device model and language on its
    /// audio, keeps its identity and metadata, and never outputs automatically.
    private func checkReadyOnDeviceRetryKeepsTheRecording(_ model: String) async throws {
        let record = try await seed(model, failure: "Transcription cancelled. Audio retained.")
        let audio = try files(record).audio
        let earlier = effects.transcriptionRequests.count
        await controller.retryHistory(record.id.uuidString, onDeviceReadiness: { _ in nil })
        let requests = effects.transcriptionRequests.dropFirst(earlier)
        let request = requests.first
        try require(
            requests.count == 1 && request?.model == model && request?.language == "fr" && request?.key == ""
                && request?.audio.lastPathComponent == record.audioFilename,
            "the retry did not run once with the recording's own model, language and audio"
        )
        let saved = try await stored(record)
        let audioAfter = try files(record).audio
        try require(
            sameRecording(saved, record) && audioAfter == audio,
            "the retry changed the recording's identity, metadata or audio"
        )
        try require(
            saved.result?.text == SyntheticEffects.batchText && saved.failure == nil,
            "the retry did not save its transcript"
        )
        try require(effects.completedOutputs == 0 && effects.heldOutputs == 0, "a History retry output automatically")
    }

    /// A failed retry keeps the transcript and audio it had; a silent one
    /// stays empty rather than gaining placeholder text.
    private func checkFailedAndSilentRetriesKeepHistory(_ model: String) async throws {
        let record = try await seed(model, failure: nil)
        let ready: @Sendable (String) -> String? = { _ in nil }
        await controller.retryHistory(record.id.uuidString, onDeviceReadiness: ready)
        let transcribed = try await stored(record)
        let audio = try files(record).audio
        effects.failNextTranscription("Synthetic on-device failure.")
        await controller.retryHistory(record.id.uuidString, onDeviceReadiness: ready)
        let failed = try await stored(record)
        let audioAfterFailure = try files(record).audio
        try require(
            failed.failure == "Synthetic on-device failure." && transcribed.displayText == SyntheticEffects.batchText
                && failed.displayText == transcribed.displayText && sameRecording(failed, record)
                && audioAfterFailure == audio,
            "a failed retry lost the recording's transcript, metadata or audio"
        )
        effects.scriptNextTranscription("")
        await controller.retryHistory(record.id.uuidString, onDeviceReadiness: ready)
        let silent = try await stored(record)
        let audioAfterSilence = try files(record).audio
        try require(
            silent.result?.text == "" && silent.displayText == "" && silent.failure == nil
                && sameRecording(silent, record) && audioAfterSilence == audio,
            "a silent retry did not stay empty, or lost its recording"
        )
    }

    /// A live-only recording keeps its import guidance and a retired model is
    /// never described as live. Neither is written or transcribed.
    private func checkLiveAndRetiredModelsKeepGuidance(_ live: String) async throws {
        let liveGuidance = await controller.retryRefusal(for: live)
        let retiredGuidance = await controller.retryRefusal(for: Self.retired)
        try require(liveGuidance?.contains("live model") == true, "a live-only recording lost its import guidance")
        try require(
            retiredGuidance?.contains("live model") == false, "a retired model was retried or described as live"
        )
        for model in [live, Self.retired] {
            let record = try await seed(model, failure: nil)
            let before = try files(record)
            let arrivals = effects.transcription.arrivals
            await controller.retryHistory(record.id.uuidString)
            let after = try files(record)
            try require(
                after == before && effects.transcription.arrivals == arrivals,
                "refusing \(model) changed its recording or transcribed"
            )
        }
    }

    /// A saved recording with audio, a language and profile notes, as capture leaves one.
    private func seed(_ model: String, failure: String?) async throws -> DesktopRecordingStore.Record {
        let id = UUID()
        var record = DesktopRecordingStore.Record(id: id, audioFilename: id.uuidString + ".wav", modelIdentifier: model)
        try SyntheticEffects.wave().write(to: history.appendingPathComponent(record.audioFilename))
        record.languageIdentifier = "fr"
        record.profileName = "Retry check"
        record.profileNotes = ["Kept on retry."]
        record.failure = failure
        try await controller.saveRecord(record)
        return record
    }

    private struct Files: Equatable {
        let metadata: Data
        let audio: Data
    }

    private func files(_ record: DesktopRecordingStore.Record) throws -> Files {
        Files(
            metadata: try Data(contentsOf: history.appendingPathComponent(record.id.uuidString + ".json")),
            audio: try Data(contentsOf: history.appendingPathComponent(record.audioFilename))
        )
    }

    private func stored(_ record: DesktopRecordingStore.Record) async throws -> DesktopRecordingStore.Record {
        try await controller.store.record(id: record.id)
    }

    /// Identity, creation time, audio file, model, language and profile notes.
    private func sameRecording(
        _ saved: DesktopRecordingStore.Record, _ original: DesktopRecordingStore.Record
    ) -> Bool {
        saved.id == original.id && saved.createdAt == original.createdAt
            && saved.audioFilename == original.audioFilename && saved.modelIdentifier == original.modelIdentifier
            && saved.languageIdentifier == original.languageIdentifier && saved.profileName == original.profileName
            && saved.profileNotes == original.profileNotes && saved.originPlatform == original.originPlatform
    }
}

private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw retryFailure(message()) }
}

private func retryFailure(_ message: String) -> WindowsNativeError {
    WindowsNativeError(message: "History retry self-test: \(message).")
}
