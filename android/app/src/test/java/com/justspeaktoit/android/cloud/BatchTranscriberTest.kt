package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

/** Upload, polling and cleanup over a scripted transport, so no provider is contacted. */
class BatchTranscriberTest {
    private val audio: File = File.createTempFile("batch", ".wav")
    private val wav = SharedAudio.Format("wav", "audio/wav")
    private val sent = mutableListOf<BatchWire.Request>()
    private var pauses = 0

    @After
    fun deleteAudio() {
        audio.delete()
    }

    /** Answers each request with the first reply whose key is a prefix of `METHOD url`. */
    private fun transcriber(
        replies: List<Pair<String, BatchWire.Response>>,
        pause: BatchPause = BatchPause { _, _ -> pauses++ },
    ): BatchTranscriber {
        val queue = replies.toMutableList()
        return BatchTranscriber(
            transport = { request, _ ->
                sent += request
                val line = "${request.method} ${request.url}"
                val index = queue.indexOfFirst { line.startsWith(it.first) }
                check(index >= 0) { "unexpected $line" }
                queue.removeAt(index).second
            },
            pause = pause,
            background = { it() },
        )
    }

    private fun ok(body: String) = BatchWire.Response(200, body)

    private fun model(id: String): CloudModel = CloudModel(
        id, id, CloudProvider.forId(id.substringBefore('/')), id.substringAfter('/'), "language",
    )

    @Test
    fun testEveryCatalogueModel_hasATranscriptionRoute() {
        val failing = BatchTranscriber(transport = { _, _ -> BatchWire.Response(401, "") }, background = {})
        for (model in CloudCatalog.transcriptionModels.filterNot { it.provider.isOpenAICompatible }) {
            val error = assertThrows(CloudException::class.java) {
                failing.transcribe(model, "k", audio, null, CallHandle(), wav, emptyList())
            }
            assertEquals("${model.catalogId} has no route", DictationFailure.InvalidKey, error.failure)
        }
    }

    @Test
    fun testAssemblyAI_pollsPastFailedReadsUntilCompleted() {
        val base = CloudProvider.AssemblyAI.baseUrl
        val text = transcriber(
            listOf(
                "POST $base/upload" to ok("""{"upload_url":"https://cdn/a"}"""),
                "POST $base/transcript" to ok("""{"id":"t1"}"""),
                "GET $base/transcript/t1" to ok("""{"status":"processing"}"""),
                "GET $base/transcript/t1" to BatchWire.Response(503, ""),
                "GET $base/transcript/t1" to ok("""{"status":"completed","text":" Hello. "}"""),
            ),
        ).transcribe(model("assemblyai/universal-3-5-pro"), " k ", audio, "en-GB", CallHandle(), wav, emptyList())
        assertEquals("Hello.", text)
        assertEquals(3, pauses)
        assertTrue(sent.all { it.headers["Authorization"] == "k" })
    }

    @Test
    fun testRevAI_fetchesTheTranscriptOnceTranscribedAndReportsAFailedJob() {
        val base = CloudProvider.RevAI.baseUrl
        val text = transcriber(
            listOf(
                "POST $base/jobs" to ok("""{"id":"j"}"""),
                "GET $base/jobs/j/transcript" to ok("""{"monologues":[{"elements":[{"value":"Hi"}]}]}"""),
                "GET $base/jobs/j" to ok("""{"status":"in_progress"}"""),
                "GET $base/jobs/j" to ok("""{"status":"transcribed"}"""),
            ),
        ).transcribe(model("revai/machine"), "k", audio, null, CallHandle(), wav, emptyList())
        assertEquals("Hi", text)
        assertEquals(1, pauses)

        val failed = transcriber(
            listOf("POST $base/jobs" to ok("""{"id":"j"}"""), "GET $base/jobs/j" to ok("""{"status":"failed"}""")),
        )
        val error = assertThrows(CloudException::class.java) {
            failed.transcribe(model("revai/machine"), "k", audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals(DictationFailure.Server, error.failure)
    }

    @Test
    fun testSoniox_deletesTheTranscriptionAndFileAfterSuccess() {
        val base = CloudProvider.Soniox.baseUrl
        val text = transcriber(
            listOf(
                "POST $base/files" to ok("""{"id":"f1"}"""),
                "POST $base/transcriptions" to ok("""{"id":"t1"}"""),
                "GET $base/transcriptions/t1/transcript" to ok("""{"text":"Hello"}"""),
                "GET $base/transcriptions/t1" to ok("""{"status":"completed"}"""),
                "DELETE $base/transcriptions/t1" to ok(""),
                "DELETE $base/files/f1" to ok(""),
            ),
        ).transcribe(model("soniox/stt-async-v4"), "k", audio, null, CallHandle(), wav, emptyList())
        assertEquals("Hello", text)
        assertEquals(
            listOf("DELETE $base/transcriptions/t1", "DELETE $base/files/f1"),
            sent.filter { it.method == "DELETE" }.map { "${it.method} ${it.url}" },
        )
    }

    @Test
    fun testSoniox_deletesTheUploadWhenTheTranscriptionFails() {
        val base = CloudProvider.Soniox.baseUrl
        val soniox = transcriber(
            listOf(
                "POST $base/files" to ok("""{"id":"f1"}"""),
                "POST $base/transcriptions" to BatchWire.Response(429, ""),
                "DELETE $base/files/f1" to ok(""),
            ),
        )
        val error = assertThrows(CloudException::class.java) {
            soniox.transcribe(model("soniox/stt-async-v4"), "k", audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals(DictationFailure.TooManyRequests, error.failure)
        assertEquals(listOf("DELETE $base/files/f1"), sent.filter { it.method == "DELETE" }.map { "${it.method} ${it.url}" })
    }

    @Test
    fun testSpeechmatics_cancelsTheJobOnlyWhenTheDictationIsAbandoned() {
        val base = CloudProvider.Speechmatics.baseUrl
        val call = CallHandle()
        val cancelled = transcriber(
            listOf(
                "POST $base/v2/jobs" to ok("""{"id":"j"}"""),
                "GET $base/v2/jobs/j" to ok("""{"job":{"status":"running"}}"""),
                "DELETE $base/v2/jobs/j?force=true" to ok(""),
            ),
            pause = BatchPause { _, handle ->
                handle.cancel()
                BatchTranscriber.SLEEP.pause(1, handle)
            },
        )
        assertThrows(CloudException::class.java) {
            cancelled.transcribe(model("speechmatics/enhanced"), "k", audio, null, call, wav, emptyList())
        }
        assertEquals("DELETE", sent.last().method)

        sent.clear()
        val rejected = transcriber(
            listOf(
                "POST $base/v2/jobs" to ok("""{"id":"j"}"""),
                "GET $base/v2/jobs/j" to ok("""{"job":{"status":"rejected"}}"""),
            ),
        )
        assertThrows(CloudException::class.java) {
            rejected.transcribe(model("speechmatics/enhanced"), "k", audio, null, CallHandle(), wav, emptyList())
        }
        assertTrue(sent.none { it.method == "DELETE" })
    }

    @Test
    fun testSleep_throwsReleasedWhenTheUserLetsTheRequestGo() {
        val call = CallHandle().apply { release() }
        assertThrows(RequestReleasedException::class.java) { BatchTranscriber.SLEEP.pause(10_000, call) }
    }

    @Test
    fun testReson8_refusesRecordingsOverItsUploadLimit() {
        RandomAccessFile(audio, "rw").use { it.setLength(BatchWire.RESON8_MAX_AUDIO_BYTES + 1) }
        val reson8 = transcriber(emptyList())
        val error = assertThrows(CloudException::class.java) {
            reson8.transcribe(model("reson8/rumble-2"), "k", audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals(DictationFailure.AudioTooLarge, error.failure)
        assertTrue(sent.isEmpty())
    }
}
