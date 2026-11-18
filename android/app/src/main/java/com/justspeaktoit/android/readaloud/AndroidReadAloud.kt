package com.justspeaktoit.android.readaloud

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.view.textclassifier.TextClassificationManager
import android.view.textclassifier.TextLanguage
import com.justspeaktoit.android.security.SecretStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.ProviderException
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private val speechAttributes: AudioAttributes = AudioAttributes.Builder()
    .setUsage(AudioAttributes.USAGE_MEDIA)
    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
    .build()

/** Builds the engine for a voice from the exported catalogue and the saved provider keys. */
internal class AndroidReadAloudEngines(
    private val context: Context,
    private val secrets: SecretStore,
    private val system: SystemSpeech,
    private val http: SpeechHttp = OkHttpSpeechHttp(),
) : (VoiceSelection) -> ReadAloudEngine {
    private val catalog by lazy { readVoiceCatalog(context) }
    private val detector = TextLanguageDetector(context)

    override fun invoke(selection: VoiceSelection): ReadAloudEngine = when (selection) {
        is VoiceSelection.System -> SystemReadAloudEngine(system, selection.voiceName)
        is VoiceSelection.Cloud -> {
            val voice = catalog.voice(selection.key) ?: throw ReadAloudException(ReadAloudFailure.VoiceUnavailable)
            val key = readKey(voice)?.takeIf { it.isNotBlank() }
                ?: throw ReadAloudException(ReadAloudFailure.MissingKey(voice.providerName))
            CloudReadAloudEngine(
                voice, key, CloudSpeechSynthesizer(http), AudioTrackOutput(),
                allowsText = {
                    com.justspeaktoit.android.cloud.CloudSharingConsentStore.preferences(context)
                        .allows(voice.provider, com.justspeaktoit.android.cloud.CloudSharedDataKind.TextToSpeak)
                },
                languageOf = { text ->
                    ReadAloudLanguage.resolve(null, detector(text), Locale.getDefault().language)
                },
            )
        }
    }

    /** A Keystore or cipher fault is reported as an unreadable key rather than escaping the tap. */
    private fun readKey(voice: CloudVoice): String? = try {
        secrets.read(voice.credentialId)
    } catch (_: GeneralSecurityException) {
        throw ReadAloudException(ReadAloudFailure.KeyUnreadable(voice.providerName))
    } catch (_: ProviderException) {
        throw ReadAloudException(ReadAloudFailure.KeyUnreadable(voice.providerName))
    }
}

/** The dominant language of a text from the phone's text classifier, or null; call off the main thread. */
internal class TextLanguageDetector(private val context: Context) : (String) -> String? {
    override fun invoke(text: String): String? = try {
        val classifier = context.getSystemService(TextClassificationManager::class.java)?.textClassifier
        val result = classifier?.detectLanguage(TextLanguage.Request.Builder(text.take(SAMPLE_CHARS)).build())
        if (result == null || result.localeHypothesisCount == 0) null else result.getLocale(0).language
    } catch (_: RuntimeException) {
        null
    }

    private companion object {
        const val SAMPLE_CHARS = 2000
    }
}

internal fun readVoiceCatalog(context: Context): VoiceCatalog =
    context.assets.open(VoiceCatalog.ASSET).bufferedReader().use { VoiceCatalog.parse(it.readText()) }

/** Holds audio focus while reading; spoken content pauses rather than ducks. */
internal class AndroidReadAloudFocus(context: Context) : ReadAloudFocus {
    private val audio: AudioManager = checkNotNull(context.getSystemService(AudioManager::class.java))
    private val main = Handler(Looper.getMainLooper())
    private var request: AudioFocusRequest? = null

    override fun request(onChange: (FocusChange) -> Unit): Boolean {
        abandon()
        val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(speechAttributes)
            .setWillPauseWhenDucked(true)
            .setOnAudioFocusChangeListener({ change ->
                if (request == null) return@setOnAudioFocusChangeListener
                when (change) {
                    AudioManager.AUDIOFOCUS_LOSS -> onChange(FocusChange.Lost)
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
                    -> onChange(FocusChange.LostTransient)
                    AudioManager.AUDIOFOCUS_GAIN -> onChange(FocusChange.Gained)
                    else -> Unit
                }
            }, main)
            .build()
        if (audio.requestAudioFocus(focus) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return false
        request = focus
        return true
    }

    override fun abandon() {
        request?.let(audio::abandonAudioFocusRequest)
        request = null
    }
}

/** Sends speech requests with OkHttp; cancelling the coroutine cancels the call. */
internal class OkHttpSpeechHttp(private val client: OkHttpClient = sharedClient) : SpeechHttp {
    override suspend fun send(request: SpeechHttpRequest): SpeechHttpResponse = suspendCancellableCoroutine { continuation ->
        val contentType = request.headers.entries.firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }?.value
        val body = if (request.method == "GET") null else request.body.toRequestBody(contentType?.toMediaType())
        val builder = Request.Builder().url(request.url).method(request.method, body)
        request.headers.forEach { (name, value) -> builder.header(name, value) }
        val call = client.newCall(builder.build())
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                val result = try {
                    response.use { SpeechHttpResponse(it.code, boundedBytes(it.body, MAX_RESPONSE_BYTES)) }
                } catch (error: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(error)
                    return
                }
                if (continuation.isActive) continuation.resume(result)
            }
        })
    }

    companion object {
        /**
         * The most a speech response may hold: a few minutes of 24 kHz 16-bit audio for the longest
         * segment, base64-encoded for Gemini, fits with room to spare; a larger body is refused.
         */
        const val MAX_RESPONSE_BYTES = 50L * 1024 * 1024

        /** The whole [body], or [SpeechResponseTooLarge] once it passes [limit] bytes; reads at most limit + 1. */
        fun boundedBytes(body: ResponseBody, limit: Long): ByteArray {
            if (body.contentLength() > limit) throw SpeechResponseTooLarge(limit)
            val source = body.source()
            if (source.request(limit + 1)) throw SpeechResponseTooLarge(limit)
            return source.buffer.readByteArray()
        }

        /**
         * Speech requests carry API keys in provider-specific headers that a redirect would forward to
         * another host, so redirects are never followed; a 3xx answer is reported as a service error.
         */
        val sharedClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .followRedirects(false)
                .followSslRedirects(false)
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .callTimeout(120, TimeUnit.SECONDS)
                .build()
        }
    }
}

/** Streams PCM to an [AudioTrack], rebuilt when a piece arrives in a different format. */
internal class AudioTrackOutput : PcmOutput {
    private val paused = MutableStateFlow(false)
    @Volatile private var track: AudioTrack? = null
    private var format: Pair<Int, Int>? = null
    private var framesWritten = 0L
    private var frameBytes = 2
    private var minBufferBytes = 0

    override suspend fun play(audio: PcmAudio) = withContext(Dispatchers.IO) {
        // A piece in another format needs a new track, so the old one finishes first.
        if (track != null && format != (audio.sampleRate to audio.channels)) drain()
        write(trackFor(audio), audio.data)
        framesWritten += audio.data.size / frameBytes
    }

    /**
     * Writes without blocking, so stopping while paused (when a full track would block a write
     * forever) cancels at once.
     */
    private suspend fun write(output: AudioTrack, data: ByteArray) {
        var offset = 0
        while (offset < data.size) {
            paused.first { !it }
            currentCoroutineContext().ensureActive()
            val size = minOf(WRITE_BYTES, data.size - offset)
            val written = output.write(data, offset, size, AudioTrack.WRITE_NON_BLOCKING)
            if (written < 0) throw ReadAloudException(ReadAloudFailure.PlaybackFailed)
            if (written == 0) delay(WRITE_WAIT_MS)
            offset += written
        }
    }

    override suspend fun drain() = withContext(Dispatchers.IO) {
        val output = track ?: return@withContext
        // A stream track can hold back a final piece smaller than its buffer, so silence fills it.
        write(output, ByteArray(minBufferBytes))
        var last = -1L
        var stalledMs = 0L
        while (true) {
            paused.first { !it }
            val head = output.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            if (head >= framesWritten) return@withContext
            stalledMs = if (head == last) stalledMs + POLL_MS else 0
            if (stalledMs >= STALL_MS) throw ReadAloudException(ReadAloudFailure.PlaybackFailed)
            last = head
            delay(POLL_MS)
        }
    }

    override fun pause() {
        paused.value = true
        track?.pause()
    }

    override fun resume() {
        paused.value = false
        track?.play()
    }

    override fun stop() {
        val output = track ?: return
        track = null
        format = null
        runCatching {
            output.pause()
            output.flush()
            output.stop()
        }
        output.release()
    }

    private fun trackFor(audio: PcmAudio): AudioTrack {
        val wanted = audio.sampleRate to audio.channels
        track?.takeIf { format == wanted }?.let { return it }
        stop()
        val mask = if (audio.channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minimum = AudioTrack.getMinBufferSize(audio.sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw ReadAloudException(ReadAloudFailure.PlaybackFailed)
        val created = try {
            AudioTrack.Builder()
                .setAudioAttributes(speechAttributes)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(audio.sampleRate)
                        .setChannelMask(mask)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(minimum * 2)
                .build()
        } catch (_: RuntimeException) {
            throw ReadAloudException(ReadAloudFailure.PlaybackFailed)
        }
        if (created.state != AudioTrack.STATE_INITIALIZED) {
            created.release()
            throw ReadAloudException(ReadAloudFailure.PlaybackFailed)
        }
        frameBytes = 2 * audio.channels
        minBufferBytes = minimum * 2 - (minimum * 2) % frameBytes
        framesWritten = 0
        format = wanted
        track = created
        if (!paused.value) created.play()
        return created
    }

    private companion object {
        const val WRITE_BYTES = 8192
        const val POLL_MS = 50L
        const val WRITE_WAIT_MS = 10L
        const val STALL_MS = 4000L
    }
}

/** A voice the phone's text-to-speech engine offers. */
data class SystemVoice(val name: String, val label: String, val needsNetwork: Boolean)

/** The phone's text-to-speech engine, started on first use and released with [release]. */
internal class SystemSpeech(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var engine: TextToSpeech? = null
    private var ready: CompletableDeferred<Boolean>? = null

    /** The started engine, or null when the phone has none. Call on the main thread. */
    suspend fun engine(): TextToSpeech? {
        val waiting = ready ?: CompletableDeferred<Boolean>().also { started ->
            ready = started
            engine = TextToSpeech(context) { status -> main.post { started.complete(status == TextToSpeech.SUCCESS) } }
        }
        if (waiting.await()) return engine
        release()
        return null
    }

    /** Installed voices, the phone's language first. */
    suspend fun voices(): List<SystemVoice> {
        val tts = engine() ?: return emptyList()
        val language = Locale.getDefault().language
        return tts.voices.orEmpty()
            .filterNot { TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED in it.features.orEmpty() }
            .sortedWith(compareBy<Voice>({ it.locale.language != language }, { it.locale.displayName }, { it.name }))
            .map { SystemVoice(it.name, "${it.locale.displayName} · ${it.name}", it.isNetworkConnectionRequired) }
    }

    fun release() {
        engine?.shutdown()
        engine = null
        ready = null
    }
}

/**
 * Reads with the phone's engine one chunk at a time, so a pause can stop the engine and a resume
 * can start again at the chunk it interrupted.
 */
internal class SystemReadAloudEngine(private val speech: SystemSpeech, private val voiceName: String?) : ReadAloudEngine {
    private enum class Outcome { Done, Interrupted, Failed }

    private val paused = MutableStateFlow(false)
    @Volatile private var tts: TextToSpeech? = null
    @Volatile private var pending: Pair<String, CompletableDeferred<Outcome>>? = null

    override suspend fun play(text: String, language: String?, onAudible: () -> Unit) {
        val engine = speech.engine() ?: throw ReadAloudException(ReadAloudFailure.SystemUnavailable)
        choose(engine)
        engine.setAudioAttributes(speechAttributes)
        engine.setOnUtteranceProgressListener(listener(onAudible))
        tts = engine
        val chunks = speechChunks(text, TextToSpeech.getMaxSpeechInputLength())
        var index = 0
        try {
            while (index < chunks.size) {
                paused.first { !it }
                val id = "$UTTERANCE_PREFIX${nextUtterance.getAndIncrement()}"
                val outcome = CompletableDeferred<Outcome>()
                pending = id to outcome
                if (engine.speak(chunks[index], TextToSpeech.QUEUE_FLUSH, null, id) == TextToSpeech.ERROR) {
                    throw ReadAloudException(ReadAloudFailure.SystemUnavailable)
                }
                when (outcome.await()) {
                    Outcome.Done -> index++
                    Outcome.Interrupted -> Unit
                    Outcome.Failed -> throw ReadAloudException(ReadAloudFailure.PlaybackFailed)
                }
            }
        } finally {
            pending = null
            tts = null
            engine.stop()
        }
    }

    override fun pause() {
        paused.value = true
        tts?.stop()
    }

    override fun resume() {
        paused.value = false
    }

    private fun choose(engine: TextToSpeech) {
        val voice = if (voiceName == null) {
            engine.defaultVoice
        } else {
            engine.voices?.firstOrNull { it.name == voiceName }
                ?: throw ReadAloudException(ReadAloudFailure.VoiceUnavailable)
        }
        if (voice != null && engine.setVoice(voice) == TextToSpeech.ERROR && voiceName != null) {
            throw ReadAloudException(ReadAloudFailure.VoiceUnavailable)
        }
    }

    private fun listener(onAudible: () -> Unit) = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {
            if (pending?.first == utteranceId) onAudible()
        }

        override fun onDone(utteranceId: String?) = complete(utteranceId, Outcome.Done)

        override fun onStop(utteranceId: String?, interrupted: Boolean) = complete(utteranceId, Outcome.Interrupted)

        override fun onError(utteranceId: String?, errorCode: Int) = complete(utteranceId, Outcome.Failed)

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) = complete(utteranceId, Outcome.Failed)
    }

    private fun complete(utteranceId: String?, outcome: Outcome) {
        val current = pending ?: return
        if (current.first == utteranceId) current.second.complete(outcome)
    }

    private companion object {
        const val UTTERANCE_PREFIX = "jsti.readAloud."

        // Process-wide: every reading shares one TextToSpeech, so a late callback for an earlier
        // reading's utterance must never match a new one.
        val nextUtterance = AtomicLong()
    }
}
