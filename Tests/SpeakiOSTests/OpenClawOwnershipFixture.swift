#if os(iOS)
import Foundation
import SpeakCore
@testable import SpeakiOSLib
import XCTest

@MainActor
final class OpenClawOwnershipGate {
    let entered = XCTestExpectation(description: "Owned operation entered")
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var signalled = false

    func wait() async {
        if !signalled {
            signalled = true
            entered.fulfill()
        }
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

/// No production client, settings, personal store, audio or platform command setup.
@MainActor
final class OpenClawOwnershipFixture {
    struct Send {
        let text: String
        let sessionKey: String
        let acknowledge: OpenClawChatDependencies.Acknowledgment
    }

    let first = OpenClawClient.Conversation(sessionKey: "fixture:first")
    let second = OpenClawClient.Conversation(sessionKey: "fixture:second")
    var rows: [String: OpenClawClient.Conversation] = [:]
    var callbacks: OpenClawChatDependencies.Callbacks?
    var sends: [Send] = []
    var connections: [String?] = []
    var disconnects = 0
    var speechStops = 0
    var spoken: [[String]] = []
    var resumes = 0
    var activityUpdates = 0
    var activityEnds = 0
    var canSpeak = false
    var readyGate: OpenClawOwnershipGate?
    var speechGate: OpenClawOwnershipGate?
    var gates: [OpenClawOwnershipGate] = []
    var onResume: (() -> Void)?
    var voiceCaptures: [OpenClawVoiceCaptureFixture] = []
    var voiceAllocations = 0
    var policy = OpenClawConversationPolicy()

    init() {
        rows[first.id] = first
        rows[second.id] = second
    }

    func makeCoordinator() -> OpenClawChatCoordinator {
        var dependencies = OpenClawChatDependencies(
            installCallbacks: { self.callbacks = $0 },
            isConfigured: { true },
            connect: { key in
                self.connections.append(key)
                self.callbacks?.connection(.connected)
            },
            disconnect: {
                self.disconnects += 1
                self.callbacks?.connection(.disconnected)
            },
            send: { self.sends.append(Send(text: $0, sessionKey: $1, acknowledge: $2)) },
            createConversation: {
                let row = OpenClawClient.Conversation(sessionKey: "fixture:new")
                self.rows[row.id] = row
                return row
            },
            conversation: { self.rows[$0] },
            addMessage: { message, id in self.rows[id]?.messages.append(message) },
            makeVoiceCapture: {
                self.voiceAllocations += 1
                guard !self.voiceCaptures.isEmpty else {
                    XCTFail("Unexpected capture allocation")
                    return OpenClawVoiceCaptureFixture()
                }
                return self.voiceCaptures.removeFirst()
            },
            waitForConnection: nil
        )
        dependencies.conversationPolicy = { self.policy }
        dependencies.waitForConnection = { await self.readyGate?.wait() }
        dependencies.canSpeak = { _ in self.canSpeak }
        dependencies.speak = { _, responses, _ in
            self.spoken.append(responses)
            await self.speechGate?.wait()
        }
        dependencies.stopSpeech = { _ in self.speechStops += 1 }
        dependencies.resumeListening = { _ in
            self.resumes += 1
            self.onResume?()
        }
        dependencies.updateActivity = { _ in self.activityUpdates += 1 }
        dependencies.endActivity = { _ in self.activityEnds += 1 }
        return OpenClawChatCoordinator(dependencies: dependencies)
    }

    func gate() -> OpenClawOwnershipGate {
        let gate = OpenClawOwnershipGate()
        gates.append(gate)
        return gate
    }

    func releaseAll() {
        for gate in gates { gate.release() }
    }

    func messages(_ row: OpenClawClient.Conversation) -> [OpenClawClient.ChatMessage] {
        rows[row.id]?.messages ?? []
    }

    func acknowledge(
        _ index: Int, _ result: Result<String, Error>, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard sends.indices.contains(index) else {
            XCTFail("Expected owned send was not enqueued", file: file, line: line)
            return
        }
        sends[index].acknowledge(result)
    }
}
#endif
