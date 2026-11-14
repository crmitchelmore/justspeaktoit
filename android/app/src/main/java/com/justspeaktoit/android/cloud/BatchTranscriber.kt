package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import java.io.File
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
 * Runs the batch providers that are not OpenAI-compatible: one upload for Deepgram, ElevenLabs,
 * Mistral, Modulate and Reson8; upload, then poll, for AssemblyAI, Rev AI, Soniox and Speechmatics.
 * Polling stops as soon as [CallHandle.cancel] runs. Soniox's uploads are always deleted, and an
 * abandoned Speechmatics job is cancelled, on a background thread so a cancel is never held up.
 */
internal class BatchTranscriber(
    private val transport: BatchTransport,
    private val pause: BatchPause = SLEEP,
    private val background: (() -> Unit) -> Unit = { task ->
        thread(isDaemon = true, name = "jsti-batch-cleanup") { runCatching(task) }
    },
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

    /** Runs [step] until it returns true; a NetworkTimeout once [attempts] are spent. */
    private inline fun poll(attempts: Int, provider: String, step: () -> Boolean) {
        repeat(attempts) { if (step()) return }
        throw CloudException(DictationFailure.NetworkTimeout, "$provider transcription timed out")
    }

    private fun send(request: BatchWire.Request, call: CallHandle): String {
        val response = transport.exchange(request, call)
        if (!response.ok) throw CloudException(CloudWire.failureForStatus(response.status), "HTTP ${response.status}")
        return response.body
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
