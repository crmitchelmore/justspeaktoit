#if DEBUG && IOS_KEYBOARD_DIRECT_CAPTURE
@available(iOS 26.0, *)
extension KeyboardWebDictationEngine {
    static let capturePage = """
    <!doctype html>
    <meta http-equiv="Content-Security-Policy"
          content="default-src 'none'; script-src 'unsafe-inline'">
    <script>
    const report = message => window.webkit.messageHandlers.capture.postMessage(message);
    let releaseCapture = () => {};
    const stopCapture = () => {
        releaseCapture();
        report({type: "stopped"});
    };
    async function record() {
        let stream;
        let context;
        let closed = false;
        releaseCapture = () => {
            closed = true;
            stream?.getTracks().forEach(track => track.stop());
            if (context && context.state !== "closed") context.close().catch(() => {});
        };
        window.addEventListener("pagehide", releaseCapture, {once: true});
        try {
            stream = await navigator.mediaDevices.getUserMedia({audio: {channelCount: 1}, video: false});
            if (closed) { releaseCapture(); return; }
            context = new AudioContext();
            const input = context.createMediaStreamSource(stream);
            const capture = context.createScriptProcessor(2048, 1, 1);
            capture.onaudioprocess = event => {
                if (closed) return;
                const frames = event.inputBuffer.getChannelData(0);
                const pcm = new DataView(new ArrayBuffer(frames.length * 2));
                for (let i = 0; i < frames.length; i++) {
                    const sample = Math.max(-1, Math.min(1, frames[i]));
                    pcm.setInt16(i * 2, sample * (sample < 0 ? 32768 : 32767), true);
                }
                report({type: "audio", pcm: btoa(String.fromCharCode(...new Uint8Array(pcm.buffer)))});
            };
            stream.getAudioTracks().forEach(track => {
                track.addEventListener("ended", () => {
                    if (!closed) report({type: "error"});
                });
            });
            await context.resume();
            if (closed) return;
            report({type: "ready", rate: context.sampleRate});
            input.connect(capture);
            // The node must be in the render graph; its output is silence.
            capture.connect(context.destination);
        } catch {
            if (!closed) report({type: "error"});
            releaseCapture();
        }
    }
    record();
    </script>
    """
}
#endif
