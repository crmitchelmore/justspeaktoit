import Foundation
import SpeakCore
import SpeakDesktopHost
import XCTest

/// Each credential operation's identity, destination and task settle together:
/// cancelling one never touches work aimed at another destination.
final class DesktopHostVoiceCredentialStateTests: XCTestCase {
    private let current = VoiceOutputCredentialDestination.selectedVoice(selectionEpoch: UUID())
    private let other = VoiceOutputCredentialDestination.selectedVoice(selectionEpoch: UUID())

    func testCancelWork_cancelsOnlyTheOperationsForThatDestination() {
        var state = DesktopHostVoiceCredentialState()
        let read = parkedTask(), write = parkedTask()
        state.readRequest = .init(id: UUID(), destination: other)
        state.readWorker = .init(destination: current, task: read)
        state.write = .init(id: UUID(), destination: other, task: write)

        state.cancelWork(for: current)

        XCTAssertTrue(read.isCancelled)
        XCTAssertFalse(write.isCancelled)
        XCTAssertEqual(state.readRequest?.destination, other)
        XCTAssertNotNil(state.readWorker, "the worker clears itself when it settles")

        state.cancelWork(for: other)
        XCTAssertTrue(write.isCancelled)
        XCTAssertNil(state.readRequest)
    }

    func testCancelWrite_matchesOnlyThePendingRequest() {
        var state = DesktopHostVoiceCredentialState()
        let write = parkedTask(), id = UUID()
        state.write = .init(id: id, destination: current, task: write)

        XCTAssertFalse(state.cancelWrite(UUID()))
        XCTAssertFalse(write.isCancelled)
        XCTAssertTrue(state.cancelWrite(id))
        XCTAssertTrue(write.isCancelled)
        XCTAssertTrue(state.isWriting, "a cancelled write keeps the store until its task settles")
    }

    func testCancelRead_forgetsTheRequestAndCancelsTheWorker() {
        var state = DesktopHostVoiceCredentialState()
        let read = parkedTask()
        state.readRequest = .init(id: UUID(), destination: current)
        state.readWorker = .init(destination: other, task: read)

        state.cancelRead()

        XCTAssertNil(state.readRequest)
        XCTAssertTrue(read.isCancelled)
    }

    func testStopProviderEdits_cancelsTheProviderWriteButNotVoiceWork() {
        var state = DesktopHostVoiceCredentialState()
        let providerWrite = Task<Void, Error> { try await Task.sleep(for: .seconds(60)) }
        let voiceWrite = parkedTask()
        state.providerWriteTask = providerWrite
        state.write = .init(id: UUID(), destination: current, task: voiceWrite)

        state.stopProviderEdits()

        XCTAssertTrue(providerWrite.isCancelled)
        XCTAssertFalse(voiceWrite.isCancelled)
        voiceWrite.cancel()
    }

    private func parkedTask() -> Task<Void, Never> {
        Task { try? await Task.sleep(for: .seconds(60)) }
    }
}
