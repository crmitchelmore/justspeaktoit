package com.justspeaktoit.android.readaloud

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

/** Plays 16-bit PCM in order, one piece after another. */
interface PcmOutput {
    /** Queues [audio], returning once it has been handed to the speaker; waits while paused. */
    suspend fun play(audio: PcmAudio)

    /** Returns once everything queued has been heard. */
    suspend fun drain()

    fun pause()

    fun resume()

    /** Silences and releases the output; safe to call more than once. */
    fun stop()
}

/**
 * Reads with a cloud voice. The next segment is fetched while the current one plays, so long text
 * starts speaking after the first request rather than the last. A text whose language is not known
 * is sent in the language [languageOf] finds for it (detected, else the phone's).
 */
class CloudReadAloudEngine(
    private val voice: CloudVoice,
    private val credential: String,
    private val synthesizer: CloudSpeechSynthesizer,
    private val output: PcmOutput,
    /** Production checks text-to-speak consent. Tests that exercise synthesis allow the request. */
    private val allowsText: () -> Boolean = { true },
    private val languageOf: (String) -> String = { ReadAloudLanguage.resolve(null, null, Locale.getDefault().language) },
) : ReadAloudEngine {
    override suspend fun play(text: String, language: String?, onAudible: () -> Unit) {
        if (!allowsText()) throw ReadAloudException(ReadAloudFailure.NeedsConsent(voice.providerName))
        val segments = synthesizer.plan(voice, text)
        try {
            coroutineScope {
                val audio = Channel<PcmAudio>(capacity = 1)
                launch {
                    // Detection can load a model, so it stays off the caller's thread.
                    val code = language ?: withContext(Dispatchers.Default) { languageOf(text) }
                    segments.forEach { audio.send(synthesizer.synthesize(voice, it, credential, code)) }
                    audio.close()
                }
                var audible = false
                for (piece in audio) {
                    if (!audible) {
                        audible = true
                        onAudible()
                    }
                    output.play(piece)
                }
                output.drain()
            }
        } finally {
            output.stop()
        }
    }

    override fun pause() = output.pause()

    override fun resume() = output.resume()
}
