import Foundation
import SpeakWatchCore
import XCTest

@MainActor
final class WatchCaptureQueueTests: XCTestCase {
    private final class TransportDouble: WatchCaptureTransport {
        var isActivated = true
        var outstanding: Set<UUID> = []
        var transfers: [(url: URL, envelope: WatchCaptureEnvelope)] = []

        func hasOutstandingTransfer(for id: UUID) -> Bool { self.outstanding.contains(id) }

        func transferFile(_ url: URL, envelope: WatchCaptureEnvelope) {
            self.transfers.append((url, envelope))
            self.outstanding.insert(envelope.id)
        }
    }

    private struct TransferError: LocalizedError {
        var errorDescription: String? { "Phone unreachable" }
    }

    private var transport = TransportDouble()
    private var files: Set<URL> = []
    private var removed: [URL] = []
    private var persisted: [[WatchCapture]] = []
    private var persistSucceeds = true
    private var scheduled: [(delay: TimeInterval, action: @MainActor () -> Void)] = []

    private func audioURL(_ id: UUID) -> URL {
        URL(fileURLWithPath: "/captures").appendingPathComponent(id.uuidString + ".m4a")
    }

    private func makeQueue(captures: [WatchCapture] = []) -> WatchCaptureQueue {
        WatchCaptureQueue(
            captures: captures,
            transport: self.transport,
            audioURL: { [unowned self] in self.audioURL($0) },
            fileExists: { [unowned self] in self.files.contains($0) },
            removeFile: { [unowned self] url in
                self.removed.append(url)
                self.files.remove(url)
            },
            persist: { [unowned self] captures in
                guard self.persistSucceeds else { return false }
                self.persisted.append(captures)
                return true
            },
            scheduleRetry: { [unowned self] delay, action in self.scheduled.append((delay, action)) }
        )
    }

    private func recordedAudio() -> UUID {
        let id = UUID()
        self.files.insert(self.audioURL(id))
        return id
    }

    func testEnqueue_beforeActivation_persistsRecordedWithoutTransfer() {
        self.transport.isActivated = false
        let queue = self.makeQueue()
        let id = self.recordedAudio()

        XCTAssertTrue(queue.enqueue(id: id, createdAt: Date(), duration: 2))

        XCTAssertEqual(queue.captures.map(\.status), [.recorded])
        XCTAssertEqual(self.persisted.last?.map(\.id), [id])
        XCTAssertTrue(self.transport.transfers.isEmpty)
    }

    func testEnqueue_whenActivated_transfersOnceWithEnvelope() {
        let queue = self.makeQueue()
        let id = self.recordedAudio()

        queue.enqueue(id: id, createdAt: Date(timeIntervalSince1970: 10), duration: 3)
        queue.enqueue(id: id, createdAt: Date(timeIntervalSince1970: 10), duration: 3)
        queue.retryPending()

        XCTAssertEqual(queue.captures.count, 1)
        XCTAssertEqual(queue.captures[0].status, .transferring)
        XCTAssertEqual(self.transport.transfers.count, 1, "An outstanding transfer must not be duplicated")
        XCTAssertEqual(self.transport.transfers[0].envelope.id, id)
        XCTAssertEqual(self.transport.transfers[0].envelope.duration, 3)
        XCTAssertEqual(self.transport.transfers[0].url, self.audioURL(id))
    }

    func testEnqueue_persistFailure_restoresPreviousQueue() {
        let queue = self.makeQueue()
        var observed: [[WatchCapture]] = []
        queue.onChange = { observed.append($0) }
        self.persistSucceeds = false

        XCTAssertFalse(queue.enqueue(id: self.recordedAudio(), createdAt: Date(), duration: 1))

        XCTAssertTrue(queue.captures.isEmpty)
        XCTAssertTrue(self.transport.transfers.isEmpty)
        XCTAssertEqual(observed.last, [])
    }

    func testStartTransfer_missingAudio_staysRecorded() {
        let queue = self.makeQueue()

        queue.enqueue(id: UUID(), createdAt: Date(), duration: 1)

        XCTAssertEqual(queue.captures.map(\.status), [.recorded])
        XCTAssertTrue(self.transport.transfers.isEmpty)
    }

    func testTransferFailure_retriesWithExponentialBackoffUpToBound() {
        let queue = self.makeQueue()
        let id = self.recordedAudio()
        queue.enqueue(id: id, createdAt: Date(), duration: 1)

        for expectedDelay in [2.0, 4.0, 8.0] {
            self.transport.outstanding.removeAll()
            queue.transferFinished(id: id, error: TransferError())
            XCTAssertEqual(queue.captures[0].status, .failed)
            XCTAssertEqual(queue.captures[0].message, "Phone unreachable")
            XCTAssertEqual(self.scheduled.last?.delay, expectedDelay)
            self.scheduled.removeLast().action()
            XCTAssertEqual(queue.captures[0].status, .transferring)
        }

        self.transport.outstanding.removeAll()
        queue.transferFinished(id: id, error: TransferError())
        XCTAssertTrue(self.scheduled.isEmpty, "In-process retries are bounded")
        XCTAssertEqual(self.transport.transfers.count, 4)
        XCTAssertEqual(queue.captures[0].status, .failed)
    }

    func testTransferSuccess_retainsAudioUntilTranscribedAck() {
        let queue = self.makeQueue()
        let id = self.recordedAudio()
        queue.enqueue(id: id, createdAt: Date(), duration: 1)

        queue.transferFinished(id: id, error: nil)
        XCTAssertEqual(queue.captures[0].status, .delivered)
        XCTAssertTrue(self.removed.isEmpty)

        queue.handleAck(WatchCaptureAck(id: id, outcome: .transcribed))
        XCTAssertEqual(queue.captures[0].status, .transcribed)
        XCTAssertEqual(self.removed, [self.audioURL(id)])
    }

    func testEarlyAck_winsOverLateTransportFailure() {
        let queue = self.makeQueue()
        let id = self.recordedAudio()
        queue.enqueue(id: id, createdAt: Date(), duration: 1)

        queue.handleAck(WatchCaptureAck(id: id, outcome: .transcribed))
        queue.transferFinished(id: id, error: TransferError())

        XCTAssertEqual(queue.captures[0].status, .transcribed)
        XCTAssertTrue(self.scheduled.isEmpty)
    }

    func testTranscribedAck_notPersisted_keepsAudio() {
        let queue = self.makeQueue()
        let id = self.recordedAudio()
        queue.enqueue(id: id, createdAt: Date(), duration: 1)
        self.persistSucceeds = false

        queue.handleAck(WatchCaptureAck(id: id, outcome: .transcribed))

        XCTAssertEqual(queue.captures[0].status, .transferring)
        XCTAssertTrue(self.removed.isEmpty, "Audio is released only after a durable acknowledgement")
    }

    func testFailedAck_recordsPhoneMessage() {
        let queue = self.makeQueue()
        let id = self.recordedAudio()
        queue.enqueue(id: id, createdAt: Date(), duration: 1)

        queue.handleAck(WatchCaptureAck(id: id, outcome: .failed))

        XCTAssertEqual(queue.captures[0].status, .failed)
        XCTAssertEqual(queue.captures[0].message, "Transcription failed on iPhone")
    }

    func testRetryPending_releasesAcknowledgedAudioAndRequeuesTheRest() {
        let done = self.recordedAudio()
        let pending = self.recordedAudio()
        let queue = self.makeQueue(captures: [
            WatchCapture(id: done, createdAt: Date(), duration: 1, status: .transcribed),
            WatchCapture(id: pending, createdAt: Date(), duration: 1, status: .transferring)
        ])

        queue.retryPending()

        XCTAssertEqual(self.removed, [self.audioURL(done)])
        XCTAssertEqual(self.transport.transfers.map(\.envelope.id), [pending])
    }

    func testEnqueue_prunesOldestTerminalCapturesButNeverInFlight() {
        self.transport.isActivated = false
        let inFlightOldest = WatchCapture(id: UUID(), createdAt: Date(), duration: 1, status: .failed)
        let terminal = (0..<WatchCaptureQueue.maxTrackedCaptures - 1).map { _ in
            WatchCapture(id: UUID(), createdAt: Date(), duration: 1, status: .transcribed)
        }
        let queue = self.makeQueue(captures: terminal + [inFlightOldest])

        queue.enqueue(id: UUID(), createdAt: Date(), duration: 1)

        XCTAssertEqual(queue.captures.count, WatchCaptureQueue.maxTrackedCaptures)
        XCTAssertTrue(queue.containsCapture(id: inFlightOldest.id))
        XCTAssertFalse(queue.containsCapture(id: terminal.last!.id))
    }

    func testPersistedFormat_isStable() throws {
        let capture = WatchCapture(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 1.5,
            status: .failed,
            message: "x"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let json = try XCTUnwrap(String(data: encoder.encode([capture]), encoding: .utf8))
        XCTAssertEqual(
            json,
            #"[{"createdAt":"1970-01-01T00:00:00Z","duration":1.5,"id":"00000000-0000-0000-0000-000000000001","#
                + #""message":"x","status":"failed"}]"#
        )
    }
}
