import Foundation
import SpeakDesktop
import CLinuxSupport

extension DesktopVoiceAudioCodec {
    /// Voice export encoding through the Linux codec adapter.
    public static let linux = DesktopVoiceAudioCodec(
        available: jsti_voice_codec_available
    ) { request, error, capacity in
        var native = JSTIVoiceCodecRequest(
            format: request.format, sample_rate: request.sampleRate, pcm: request.pcm, pcm_bytes: request.pcmBytes,
            output: request.output, cancelled: request.cancelled, context: request.context
        )
        return jsti_voice_codec_encode(&native, error, capacity)
    }
}
