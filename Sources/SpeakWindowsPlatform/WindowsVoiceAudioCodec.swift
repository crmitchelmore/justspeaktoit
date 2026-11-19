import Foundation
import SpeakDesktop
import CWindowsSupport

extension DesktopVoiceAudioCodec {
    /// Voice export encoding through the Windows codec adapter.
    public static let windows = DesktopVoiceAudioCodec(
        available: jsti_voice_codec_available
    ) { request, error, capacity in
        var native = JSTIVoiceCodecRequest(
            format: request.format, sample_rate: request.sampleRate, pcm: request.pcm, pcm_bytes: request.pcmBytes,
            output: request.output, cancelled: request.cancelled, context: request.context
        )
        return jsti_voice_codec_encode(&native, error, capacity)
    }
}
