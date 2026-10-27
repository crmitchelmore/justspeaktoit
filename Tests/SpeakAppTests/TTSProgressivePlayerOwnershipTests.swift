import AVFoundation
import XCTest

@testable import SpeakApp

final class TTSProgressivePlayerOwnershipTests: XCTestCase {
    @MainActor
    func testCancelledOwnedPreparationDoesNotCreateAnEngine() async {
        var enginesCreated = 0
        let player = TTSProgressivePlayer(makeEngine: {
            enginesCreated += 1
            return AVAudioEngine()
        })
        let task = Task { @MainActor in try player.prepareOwned(sampleRate: 24_000) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Queued cancellation must be refused before stop or native preparation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(enginesCreated, 0)
        XCTAssertFalse(player.isActive)
    }

    @MainActor
    func testReplacedWrapperDeletesOnlyItsUnpublishedClientResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldFile = directory.appendingPathComponent("old-result.wav")
        let replacementFile = directory.appendingPathComponent("replacement-result.wav")
        try Data("owned old result".utf8).write(to: oldFile)
        try Data("different owned result".utf8).write(to: replacementFile)
        let firstEngine = try offlineEngine()
        let replacementEngine = try offlineEngine()
        var enginesCreated = 0
        let player = TTSProgressivePlayer(makeEngine: {
            enginesCreated += 1
            return enginesCreated == 1 ? firstEngine : replacementEngine
        })
        defer { player.stop() }
        let entered = expectation(description: "Old client is held before returning its completed artifact")
        let settled = expectation(description: "Replaced wrapper settled")
        let client = OwnedResultProgressiveClient(file: oldFile, onEntered: { entered.fulfill() })
        var outcome: Result<TTSResult, Error>?
        let task = Task { @MainActor in
            do {
                outcome = .success(try await player.speak(
                    text: "Hello", voice: "xai/eve", settings: TTSSettings(), using: client
                ))
            } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        do {
            let replacement = try player.prepareOwned(sampleRate: 24_000)
            await client.release()
            await fulfillment(of: [settled], timeout: 2)
            guard let outcome else { XCTFail("Owned wrapper failed to settle"); return }
            if case .failure(let error) = outcome { XCTAssertTrue(error is CancellationError) } else {
                XCTFail("Superseded wrapper must not transfer a result to its manager")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: replacementFile.path))
            XCTAssertTrue(player.isActive, "Old cleanup must not stop the replacement generation")
            try await player.waitUntilDrained(session: replacement)
        } catch {
            await client.release()
            task.cancel()
            await fulfillment(of: [settled], timeout: 2)
            throw error
        }
    }

    @MainActor
    func testSuccessfulWrapperTransfersCompletedFileWithoutDeletingIt() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("owned completed artifact".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try offlineEngine()
        let player = TTSProgressivePlayer(makeEngine: { engine })
        defer { player.stop() }
        let client = OwnedResultProgressiveClient(file: file, onEntered: {})
        await client.release()
        let result = try await player.speak(text: "Hello", voice: "xai/eve", settings: TTSSettings(), using: client)
        XCTAssertEqual(result.audioURL, file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(player.isActive)
    }

    @MainActor
    func testCancelledHeldClientCannotTransferItsCompletedFileWithoutReplacement() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("owned cancelled artifact".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try offlineEngine()
        let player = TTSProgressivePlayer(makeEngine: { engine })
        defer { player.stop() }
        let entered = expectation(description: "Client is held before returning file")
        let settled = expectation(description: "Cancelled wrapper settled")
        let client = OwnedResultProgressiveClient(file: file, onEntered: { entered.fulfill() })
        var outcome: Result<TTSResult, Error>?
        let task = Task { @MainActor in
            do {
                outcome = .success(try await player.speak(
                    text: "Hello", voice: "xai/eve", settings: TTSSettings(), using: client
                ))
            } catch { outcome = .failure(error) }
            settled.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        // This fixture deliberately ignores cancellation until explicitly released.
        await client.release()
        await fulfillment(of: [settled], timeout: 2)
        guard let outcome else { XCTFail("Owned cancelled wrapper failed to settle"); return }
        if case .failure(let error) = outcome { XCTAssertTrue(error is CancellationError) } else {
            XCTFail("A cancelled result cannot be handed to the manager")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(player.isActive)
    }

    /// Configure offline mode before reading the mixer, as the SDK requires.
    /// These tests exercise wrapper/file identity; they never request rendering.
    private func offlineEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        return engine
    }
}

private actor OwnedResultProgressiveClient: ProgressiveTextToSpeechClient {
    let provider = TTSProvider.xai
    let progressiveSampleRate = 24_000
    private let file: URL
    private let onEntered: @Sendable () -> Void
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(file: URL, onEntered: @escaping @Sendable () -> Void) {
        self.file = file
        self.onEntered = onEntered
    }

    func synthesizeProgressively(
        text: String, voice: String, settings: TTSSettings,
        onAudioChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> TTSResult {
        onEntered()
        if !released { await withCheckedContinuation { waiter = $0 } }
        return TTSResult(audioURL: file, provider: provider, voice: voice, duration: 0, characterCount: text.count)
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }

    func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
        throw TTSError.synthesisFailure("Unused fixture path")
    }

    func listVoices() async throws -> [TTSVoice] { [] }
    func validateAPIKey(_ key: String) async -> APIKeyValidationResult { .failure(message: "Unused fixture path") }
}
