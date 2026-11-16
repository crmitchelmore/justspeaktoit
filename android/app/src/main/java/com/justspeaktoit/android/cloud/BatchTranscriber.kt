package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import java.io.File
import java.util.Locale
import kotlin.concurrent.thread

/** Performs one request. A non-2xx response comes back with an empty body rather than throwing. */
internal fun interface BatchTransport {
    fun exchange(request: BatchWire.Request, call: CallHandle): BatchWire.Response
}

/** Waits between status polls; throws as soon as the call is cancelled. */
internal fun interface BatchPause {
    fun pause(ms: Long, call: CallHandle)
}

/**
 * Runs the batch providers that are not OpenAI-compatible: one upload for Alibaba, Azure, Cartesia,
 * Deepgram, ElevenLabs, Meta, Mistral, Modulate, OpenRouter, Reson8, Smallest, StepFun and xAI; upload, then poll, for
 * AssemblyAI, Gladia, Rev AI, Soniox and Speechmatics; inline audio, or a Files API upload for a large
 * recording, for Gemini. Polling stops as soon as [CallHandle.cancel] runs. Soniox's uploads are always
 * deleted, and an abandoned Gladia or Speechmatics job is cancelled, on a background thread so a cancel
 * is never held up.
 */
internal class BatchTranscriber(
    private val transport: BatchTransport,
    private val pause: BatchPause = SLEEP,
    private val background: (() -> Unit) -> Unit = { task ->
        thread(isDaemon = true, name = "jsti-batch-cleanup") { runCatching(task) }
    },
    /** The saved Azure Speech resource endpoint, or blank for the key's regional origin. */
    private val azureEndpoint: () -> String = { "" },
) {
    fun transcribe(
        model: CloudModel,
        apiKey: String,
        audio: File,
        languageTag: String?,
        call: CallHandle,
        format: SharedAudio.Format,
        vocabulary: List<String>,
    ): String {
        val key = apiKey.trim()
        val base = model.provider.baseUrl
        val id = model.catalogId
        return when (model.provider) {
            CloudProvider.Deepgram -> BatchWire.deepgramText(
                send(BatchWire.deepgram(base, id, key, audio, format, languageTag, vocabulary), call),
            )
            CloudProvider.ElevenLabs -> BatchWire.requiredString(
                send(BatchWire.elevenLabs(base, id, key, audio, format, languageTag, vocabulary), call),
                "text",
            )
            CloudProvider.Mistral -> BatchWire.mistralText(
                send(BatchWire.mistral(base, id, key, audio, format, languageTag, vocabulary), call),
            )
            CloudProvider.Modulate -> BatchWire.modulateText(
                send(BatchWire.modulate(base, id, key, audio, format), call),
                id,
            )
            CloudProvider.Reson8 -> reson8(model, key, audio, format, languageTag, call)
            CloudProvider.AssemblyAI -> assemblyAI(base, id, key, audio, languageTag, vocabulary, call)
            CloudProvider.RevAI -> revAI(base, key, audio, format, languageTag, call)
            CloudProvider.Soniox -> soniox(base, id, key, audio, format, languageTag, vocabulary, call)
            CloudProvider.Speechmatics -> speechmatics(base, id, key, audio, format, languageTag, vocabulary, call)
            CloudProvider.Cartesia -> BatchWire.cartesiaText(
                send(BatchWire.cartesia(model, key, audio, format, languageTag), call),
            )
            CloudProvider.Smallest -> {
                requireAtMost(audio, BatchWire.SMALLEST_MAX_AUDIO_BYTES, "Smallest takes at most 25 MiB")
                BatchWire.smallestText(send(BatchWire.smallest(model, key, audio, languageTag), call))
            }
            CloudProvider.XAI -> {
                requireAtMost(audio, BatchWire.XAI_MAX_AUDIO_BYTES, "xAI takes at most 500 MB")
                BatchWire.xaiText(send(BatchWire.xai(model, key, audio, format, languageTag, vocabulary), call))
            }
            CloudProvider.Meta -> meta(model, key, audio, languageTag, vocabulary, call)
            CloudProvider.Gladia -> gladia(model, key, audio, format, languageTag, call)
            CloudProvider.Google -> gemini(key, audio, format, languageTag, call)
            CloudProvider.OpenRouter -> openRouter(model, key, audio, format, languageTag, call)
            CloudProvider.Azure -> azure(model, key, audio, languageTag, vocabulary, call)
            CloudProvider.Alibaba -> alibaba(model, key, audio, languageTag, call)
            CloudProvider.StepFun -> stepFun(key, audio, format, languageTag, call)
            else -> throw CloudException(DictationFailure.Unavailable, "No batch route for ${model.provider.id}")
        }
    }

    private fun reson8(
        model: CloudModel,
        key: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        call: CallHandle,
    ): String {
        if (audio.length() > BatchWire.RESON8_MAX_AUDIO_BYTES) {
            throw CloudException(DictationFailure.AudioTooLarge, "Reson8 takes at most 25 MiB")
        }
        return BatchWire.requiredString(send(BatchWire.reson8(model, key, audio, format, languageTag), call), "text")
    }

    private fun assemblyAI(
        base: String,
        id: String,
        key: String,
        audio: File,
        languageTag: String?,
        vocabulary: List<String>,
        call: CallHandle,
    ): String {
        val uploadUrl = BatchWire.assemblyAIUploadUrl(send(BatchWire.assemblyAIUpload(base, key, audio), call))
        val transcriptId = BatchWire.requiredString(
            send(BatchWire.assemblyAISubmit(base, id, key, uploadUrl, languageTag, vocabulary), call),
            "id",
        )
        var text: String? = null
        poll(BatchWire.ASSEMBLYAI_POLL_ATTEMPTS, "AssemblyAI") {
            pause.pause(BatchWire.ASSEMBLYAI_POLL_MS, call)
            val response = transport.exchange(BatchWire.assemblyAIPoll(base, key, transcriptId), call)
            // As on the Mac, a failed status read is retried rather than ending the transcription.
            if (!response.ok) return@poll false
            when (BatchWire.optionalString(response.body, "status")) {
                "completed" -> {
                    text = BatchWire.optionalString(response.body, "text").orEmpty().trim()
                    true
                }
                "error" -> throw CloudException(
                    DictationFailure.Server,
                    BatchWire.optionalString(response.body, "error") ?: "Unknown transcription error",
                )
                else -> false
            }
        }
        return text.orEmpty()
    }

    private fun revAI(
        base: String,
        key: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        call: CallHandle,
    ): String {
        val jobId = BatchWire.requiredString(send(BatchWire.revAISubmit(base, key, audio, format, languageTag), call), "id")
        poll(BatchWire.REVAI_POLL_ATTEMPTS, "Rev AI") {
            when (BatchWire.optionalString(send(BatchWire.revAIPoll(base, key, jobId), call), "status")) {
                "transcribed" -> true
                "failed" -> throw CloudException(DictationFailure.Server, "Rev AI transcription failed")
                else -> {
                    pause.pause(BatchWire.REVAI_POLL_MS, call)
                    false
                }
            }
        }
        return BatchWire.revAIText(send(BatchWire.revAITranscript(base, key, jobId), call))
    }

    private fun soniox(
        base: String,
        id: String,
        key: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        vocabulary: List<String>,
        call: CallHandle,
    ): String {
        val fileId = BatchWire.requiredString(send(BatchWire.sonioxUpload(base, key, audio, format), call), "id")
        var transcriptionPath: String? = null
        try {
            val transcriptionId = BatchWire.requiredString(
                send(BatchWire.sonioxCreate(base, id, key, fileId, languageTag, vocabulary), call),
                "id",
            )
            val path = "transcriptions/${BatchWire.pathSegment(transcriptionId)}"
            transcriptionPath = path
            poll(BatchWire.SONIOX_POLL_ATTEMPTS, "Soniox") {
                val body = send(BatchWire.sonioxGet(base, key, path), call)
                when (BatchWire.optionalString(body, "status")) {
                    "completed" -> true
                    "error" -> throw CloudException(
                        DictationFailure.Server,
                        BatchWire.optionalString(body, "error_message")
                            ?: BatchWire.optionalString(body, "error_type") ?: "Unknown error",
                    )
                    else -> {
                        pause.pause(BatchWire.SONIOX_POLL_MS, call)
                        false
                    }
                }
            }
            return BatchWire.sonioxText(send(BatchWire.sonioxGet(base, key, "$path/transcript"), call))
        } finally {
            // Soniox keeps uploads and transcriptions until deleted, so both go whatever happened.
            val paths = listOfNotNull(transcriptionPath, "files/${BatchWire.pathSegment(fileId)}")
            cleanup(paths.map { BatchWire.sonioxDelete(base, key, it) })
        }
    }

    private fun speechmatics(
        base: String,
        id: String,
        key: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        vocabulary: List<String>,
        call: CallHandle,
    ): String {
        val jobId = BatchWire.requiredString(
            send(BatchWire.speechmaticsSubmit(base, id, key, audio, format, languageTag, vocabulary), call),
            "id",
        )
        try {
            poll((BatchWire.SPEECHMATICS_TIMEOUT_MS / BatchWire.SPEECHMATICS_POLL_MS).toInt(), "Speechmatics") {
                BatchWire.speechmaticsDone(send(BatchWire.speechmaticsPoll(base, key, jobId), call)).also { done ->
                    if (!done) pause.pause(BatchWire.SPEECHMATICS_POLL_MS, call)
                }
            }
            return BatchWire.speechmaticsText(send(BatchWire.speechmaticsTranscript(base, key, jobId), call))
        } catch (e: Exception) {
            // An accepted job bills until it finishes, so one nobody will read is cancelled.
            val timedOut = e is CloudException && e.failure == DictationFailure.NetworkTimeout
            if (call.cancelled || timedOut) cleanup(listOf(BatchWire.speechmaticsDelete(base, key, jobId)))
            throw e
        }
    }

    private fun requireAtMost(audio: File, maxBytes: Long, message: String) {
        if (audio.length() > maxBytes) throw CloudException(DictationFailure.AudioTooLarge, message)
    }

    private fun meta(
        model: CloudModel,
        key: String,
        audio: File,
        languageTag: String?,
        vocabulary: List<String>,
        call: CallHandle,
    ): String {
        BatchWire.requirePcm16Wav(audio, BatchWire.META_MAX_SECONDS, BatchWire.META_MAX_AUDIO_BYTES)
        val response = transport.exchange(BatchWire.meta(model, key, audio, languageTag, vocabulary), call)
        if (!response.ok) throw CloudException(BatchWire.metaFailure(response.status), "HTTP ${response.status}")
        return BatchWire.metaText(response.body)
    }

    private fun azure(
        model: CloudModel,
        key: String,
        audio: File,
        languageTag: String?,
        vocabulary: List<String>,
        call: CallHandle,
    ): String {
        val connection = AzureSpeechCredential.connection(key, azureEndpoint())
        BatchWire.requirePcm16Wav(audio, BatchWire.META_MAX_SECONDS, BatchWire.META_MAX_AUDIO_BYTES)
        val response = exchangeOk(BatchWire.azure(connection, model, audio, languageTag, vocabulary), call)
        // As on the Mac, only 200 carries a transcript.
        if (response.status != 200) throw CloudException(DictationFailure.Server, "HTTP ${response.status}")
        return BatchWire.azureText(response.body)
    }

    private fun alibaba(model: CloudModel, key: String, audio: File, languageTag: String?, call: CallHandle): String {
        val credential = AlibabaCredential.parse(key) ?: throw CloudException(
            DictationFailure.InvalidKey,
            "Set the Alibaba region and workspace ID, then save the API key from that same region.",
        )
        if (!BatchWire.alibabaSupportsRegion(model.catalogId, credential.region)) {
            throw CloudException(
                DictationFailure.InvalidKey,
                "Fun-ASR and Qwen3.5-Omni-Plus require a Beijing or Singapore workspace and regional key.",
            )
        }
        BatchWire.requirePcm16Wav(
            audio,
            BatchWire.alibabaMaxSeconds(model.catalogId),
            BatchWire.ALIBABA_MAX_AUDIO_BYTES + 1,
        )
        // A general audio model can describe silence, so a silent recording is never sent.
        if (WavFormat.isSilent(audio)) return ""
        val body = send(BatchWire.alibaba(credential, model, audio, languageTag), call)
        return if (model.catalogId == BatchWire.ALIBABA_FUN_FLASH) {
            BatchWire.alibabaFunText(body)
        } else {
            BatchWire.alibabaOmniText(body)
        }
    }

    private fun stepFun(
        key: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        call: CallHandle,
    ): String {
        val credential = StepFunCredential.parse(key) ?: throw CloudException(
            DictationFailure.InvalidKey,
            "Enter a StepFun API key. Choose its region in Settings > API keys before saving.",
        )
        val audioFormat = BatchWire.stepFunFormat(format)
            ?: throw CloudException(DictationFailure.UnsupportedAudio, "StepFun cannot read ${format.extension}")
        requireAtMost(audio, BatchWire.STEPFUN_MAX_AUDIO_BYTES, "StepFun takes at most 25 MiB")
        val response = transport.exchange(BatchWire.stepFun(credential, audio, audioFormat, languageTag), call)
        if (!response.ok) {
            // Keys are region-bound: report the region rather than trying the other one.
            if (response.status == 401 || response.status == 403) {
                throw CloudException(
                    DictationFailure.InvalidKey,
                    "StepFun rejected this key for the ${credential.region.displayName} region " +
                        "(HTTP ${response.status}). Keys only work in the region that issued them.",
                )
            }
            throw CloudException(CloudWire.failureForStatus(response.status), "HTTP ${response.status}")
        }
        if (!BatchWire.isEventStream(response)) throw CloudException(DictationFailure.Server, "Unexpected response")
        return BatchWire.stepFunText(response.body)
    }

    private fun gladia(
        model: CloudModel,
        key: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        call: CallHandle,
    ): String {
        val base = model.provider.baseUrl
        val audioUrl = BatchWire.gladiaAudioUrl(send(BatchWire.gladiaUpload(base, key, audio, format), call))
        val job = BatchWire.gladiaJob(send(BatchWire.gladiaSubmit(model, key, audioUrl, languageTag), call), base)
        try {
            var text: String? = null
            poll((BatchWire.GLADIA_TIMEOUT_MS / BatchWire.GLADIA_POLL_MS).toInt(), "Gladia") {
                text = BatchWire.gladiaResult(send(BatchWire.gladiaPoll(key, job), call))
                (text != null).also { done -> if (!done) pause.pause(BatchWire.GLADIA_POLL_MS, call) }
            }
            return text.orEmpty()
        } catch (e: Exception) {
            // An accepted job bills until it finishes, so one nobody will read is cancelled.
            val timedOut = e is CloudException && e.failure == DictationFailure.NetworkTimeout
            val jobId = job.id
            if ((call.cancelled || timedOut) && jobId != null) cleanup(listOf(BatchWire.gladiaDelete(base, key, jobId)))
            throw e
        }
    }

    private fun gemini(key: String, audio: File, format: SharedAudio.Format, languageTag: String?, call: CallHandle): String {
        val request = if (audio.length() <= BatchWire.GEMINI_INLINE_BYTES) {
            BatchWire.geminiInline(key, audio, format, languageTag)
        } else {
            BatchWire.geminiFromFile(key, geminiUpload(key, audio, format, call), format, languageTag)
        }
        return BatchWire.geminiText(send(request, call))
    }

    /** The Files API's resumable upload, then polls until Google has processed the recording. */
    private fun geminiUpload(key: String, audio: File, format: SharedAudio.Format, call: CallHandle): String {
        val start = exchangeOk(BatchWire.geminiUploadStart(key, audio, format), call)
        val uploadUrl = start.headers["x-goog-upload-url"]
            ?: throw CloudException(DictationFailure.Server, "The upload session URL was missing")
        val file = BatchWire.geminiUploadedFile(send(BatchWire.geminiUpload(uploadUrl, audio, format), call))
        if (geminiFileReady(file.state)) return file.uri
        val name = file.name ?: throw CloudException(DictationFailure.Server, "The upload response did not name the file")
        poll(BatchWire.GEMINI_FILE_POLL_ATTEMPTS, "Gemini file processing") {
            pause.pause(BatchWire.GEMINI_FILE_POLL_MS, call)
            geminiFileReady(BatchWire.geminiFileState(send(BatchWire.geminiFileStatus(key, name), call)))
        }
        return file.uri
    }

    private fun geminiFileReady(state: String?): Boolean = when (state?.uppercase(Locale.ROOT)) {
        "ACTIVE" -> true
        "FAILED" -> throw CloudException(DictationFailure.Server, "Google could not process the uploaded recording")
        else -> false
    }

    private fun openRouter(
        model: CloudModel,
        key: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        call: CallHandle,
    ): String {
        OpenRouterTranscriptionSelection.modelId(model.catalogId)?.let { slug ->
            return openRouterSpeechToText(slug, key, audio, format, languageTag, call)
        }
        val audioFormat = BatchWire.openRouterFormat(format)
            ?: throw CloudException(DictationFailure.UnsupportedAudio, "OpenRouter cannot read ${format.extension}")
        requireAtMost(audio, BatchWire.OPENROUTER_MAX_AUDIO_BYTES, "OpenRouter takes at most 50 MiB inline")
        val wireFormat = if (model.requiresPCM16WAV) {
            BatchWire.requirePcm16Wav(audio, BatchWire.INKLING_MAX_SECONDS, BatchWire.OPENROUTER_MAX_AUDIO_BYTES)
            "wav"
        } else {
            audioFormat
        }
        return BatchWire.openRouterText(send(BatchWire.openRouter(model, key, audio, wireFormat, languageTag), call))
    }

    /** A discovered speech-to-text model goes to OpenRouter's dedicated endpoint, not chat completions. */
    private fun openRouterSpeechToText(
        slug: String,
        key: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        call: CallHandle,
    ): String {
        val audioFormat = BatchWire.openRouterSpeechToTextFormat(format)
            ?: throw CloudException(DictationFailure.UnsupportedAudio, "OpenRouter cannot read ${format.extension}")
        requireAtMost(audio, BatchWire.OPENROUTER_STT_MAX_AUDIO_BYTES, "OpenRouter takes at most 25 MiB")
        val request = BatchWire.openRouterSpeechToText(slug, key, audio, audioFormat, languageTag)
        return BatchWire.openRouterSpeechToTextText(send(request, call))
    }

    /** Runs [step] until it returns true; a NetworkTimeout once [attempts] are spent. */
    private inline fun poll(attempts: Int, provider: String, step: () -> Boolean) {
        repeat(attempts) { if (step()) return }
        throw CloudException(DictationFailure.NetworkTimeout, "$provider transcription timed out")
    }

    private fun send(request: BatchWire.Request, call: CallHandle): String = exchangeOk(request, call).body

    private fun exchangeOk(request: BatchWire.Request, call: CallHandle): BatchWire.Response {
        val response = transport.exchange(request, call)
        if (!response.ok) throw CloudException(CloudWire.failureForStatus(response.status), "HTTP ${response.status}")
        return response
    }

    /** Best effort, with its own handle: the dictation's call may already be cancelled. */
    private fun cleanup(requests: List<BatchWire.Request>) {
        background {
            for (request in requests) runCatching { transport.exchange(request, CallHandle()) }
        }
    }

    companion object {
        private const val PAUSE_SLICE_MS = 100L

        /** Sleeps in short slices so a cancelled call stops polling within [PAUSE_SLICE_MS]. */
        val SLEEP = BatchPause { ms, call ->
            val end = System.nanoTime() + ms * 1_000_000
            while (true) {
                if (call.released) throw RequestReleasedException()
                if (call.cancelled) throw CloudException(DictationFailure.Network, "Cancelled")
                val left = (end - System.nanoTime()) / 1_000_000
                if (left <= 0) break
                Thread.sleep(minOf(left, PAUSE_SLICE_MS))
            }
        }
    }
}
