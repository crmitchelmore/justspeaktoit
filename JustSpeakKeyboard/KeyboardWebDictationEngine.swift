#if (DEBUG && IOS_KEYBOARD_DIRECT_CAPTURE) || IOS_KEYBOARD_WEB_CAPTURE
import AVFoundation
import os
import SpeakCore
import UIKit
import WebKit

@available(iOS 26.0, *)
@MainActor
final class KeyboardWebDictationEngine: NSObject, KeyboardDictationEngineProtocol,
    WKNavigationDelegate, WKUIDelegate {
    private static let captureHost = "keyboard.justspeaktoit.invalid"
    private static let origin = URL(string: "https://\(captureHost)/")
    private static let log = Logger(subsystem: "com.justspeaktoit.keyboard", category: "web-dictation")

    var onEvent: ((UUID, KeyboardDictationMachine.Event) -> Void)?
    private let host: () -> UIView?
    private var activeRunID: UUID?
    private var webView: WKWebView?
    private var speech: AppleSpeechAnalyzerLiveSession?
    private var inputFormat: AVAudioFormat?
    private var converter: AppleSpeechAudioConverter?
    private var stopRequested = false
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    init(host: @escaping () -> UIView?) {
        self.host = host
    }

    static var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    func start(runID: UUID, localeIdentifier: String) {
        guard activeRunID == nil else { return }
        activeRunID = runID
        guard Self.hasMicrophonePermission,
              os_proc_available_memory() >= 32 * 1_024 * 1_024, host() != nil else {
            fail(.microphoneUnavailable, reason: "Microphone, view or memory unavailable", runID: runID)
            return
        }
        armDeadline(15, failure: .microphoneUnavailable, runID: runID)
        operation = Task { [weak self] in
            do {
                let session = try await AppleSpeechAnalyzerLiveSession(
                    localeIdentifier: localeIdentifier, assetPolicy: .installedOnly, onUpdate: { _ in }
                )
                guard let self, activeRunID == runID else {
                    await session.cancel()
                    return
                }
                guard let view = host(), os_proc_available_memory() >= 24 * 1_024 * 1_024 else {
                    await session.cancel()
                    fail(.microphoneUnavailable, reason: "View or memory no longer available", runID: runID)
                    return
                }
                speech = session
                showCapture(in: view, runID: runID)
            } catch {
                self?.fail(.speechRecognitionUnavailable, reason: error.localizedDescription, runID: runID)
            }
        }
    }

    func stop(runID: UUID) {
        guard activeRunID == runID, let webView, !stopRequested else { return }
        stopRequested = true
        armDeadline(2, failure: .audioInterrupted, runID: runID)
        webView.evaluateJavaScript("stopCapture()") { [weak self] _, error in
            guard let error else { return }
            self?.fail(.audioInterrupted, reason: error.localizedDescription, runID: runID)
        }
    }

    private func finalize(_ speech: AppleSpeechAnalyzerLiveSession, runID: UUID) {
        closeCapture()
        armDeadline(10, failure: .audioInterrupted, runID: runID)
        operation = Task { [weak self] in
            do {
                let result = try await speech.finish()
                guard let self, activeRunID == runID else { return }
                clearRun()
                onEvent?(runID, .finalized(result.text))
            } catch {
                self?.fail(.audioInterrupted, reason: error.localizedDescription, runID: runID)
            }
        }
    }

    func cancel(runID: UUID) {
        guard activeRunID == runID else { return }
        let session = speech
        clearRun()
        if let session { Task { await session.cancel() } }
    }

    private func fail(_ failure: KeyboardDictationMachine.Failure, reason: String, runID: UUID) {
        guard activeRunID == runID else { return }
        Self.log.error("Web dictation failed: \(reason, privacy: .private)")
        cancel(runID: runID)
        onEvent?(runID, .captureFailed(failure))
    }

    private func armDeadline(_ seconds: Int, failure: KeyboardDictationMachine.Failure, runID: UUID) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            self?.fail(failure, reason: "Time limit reached", runID: runID)
        }
    }

    private func clearRun() {
        activeRunID = nil
        stopRequested = false
        deadline?.cancel()
        deadline = nil
        operation?.cancel()
        operation = nil
        speech = nil
        closeCapture()
    }

    private func closeCapture() {
        guard let view = webView else { return }
        webView = nil
        inputFormat = nil
        converter = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "capture")
        view.evaluateJavaScript("releaseCapture()", completionHandler: nil)
        view.setMicrophoneCaptureState(.none, completionHandler: nil)
        view.removeFromSuperview()
    }

    private func showCapture(in host: UIView, runID: UUID) {
        guard let origin = Self.origin else {
            fail(.microphoneUnavailable, reason: "Invalid capture page origin", runID: runID)
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(KeyboardCaptureMessageHandler(engine: self), name: "capture")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.alpha = 0.02
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        host.addSubview(view)
        view.loadHTMLString(Self.capturePage, baseURL: origin)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard webView === self.webView, action.targetFrame?.isMainFrame == true,
              let origin = Self.origin, action.request.url == origin else { return .cancel }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        guard webView === self.webView, activeRunID != nil, type == .microphone,
              frame.isMainFrame, Self.isCaptureOrigin(origin),
              os_proc_available_memory() >= 24 * 1_024 * 1_024,
              Self.hasMicrophonePermission else { return .deny }
        return .grant
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, let runID = activeRunID else { return }
        fail(.microphoneUnavailable, reason: "Web content process ended", runID: runID)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        guard webView === self.webView, let runID = activeRunID else { return }
        fail(.microphoneUnavailable, reason: error.localizedDescription, runID: runID)
    }

    private static func isCaptureOrigin(_ origin: WKSecurityOrigin) -> Bool {
        origin.protocol == "https" && origin.host == captureHost && (origin.port == 0 || origin.port == 443)
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let view = webView, message.webView === view,
              message.frameInfo.isMainFrame, Self.isCaptureOrigin(message.frameInfo.securityOrigin),
              let runID = activeRunID, let speech,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            setInput(sampleRate: body["rate"] as? Double, target: speech.audioFormat, runID: runID)
        case "stopped":
            if stopRequested { finalize(speech, runID: runID) }
        case "audio":
            guard let inputFormat, let converter, let encoded = body["pcm"] as? String,
                  let buffer = Self.decode(encoded, format: inputFormat),
                  let audio = converter.convert(buffer) else {
                fail(.audioInterrupted, reason: "Invalid microphone audio", runID: runID)
                return
            }
            speech.send(audio)
        default:
            fail(.microphoneUnavailable, reason: "Web microphone unavailable", runID: runID)
        }
    }

    private func setInput(sampleRate: Double?, target: AVAudioFormat, runID: UUID) {
        guard inputFormat == nil, let sampleRate, (8_000...96_000).contains(sampleRate),
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false
              ) else {
            fail(.microphoneUnavailable, reason: "Invalid sample rate", runID: runID)
            return
        }
        do {
            converter = try AppleSpeechAudioConverter(sourceFormat: format, targetFormat: target)
            inputFormat = format
            armDeadline(60, failure: .audioInterrupted, runID: runID)
            onEvent?(runID, .captureStarted)
        } catch {
            fail(.audioInterrupted, reason: error.localizedDescription, runID: runID)
        }
    }

    private static func decode(_ encoded: String, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard encoded.utf8.count <= 5_464, let bytes = Data(base64Encoded: encoded),
              bytes.count == 4_096,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048),
              let samples = buffer.int16ChannelData?[0] else { return nil }
        buffer.frameLength = 2_048
        bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: bytes.count))
        return buffer
    }
}

@available(iOS 26.0, *)
private final class KeyboardCaptureMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var engine: KeyboardWebDictationEngine?

    init(engine: KeyboardWebDictationEngine) {
        self.engine = engine
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        engine?.receive(message)
    }
}
#endif
