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
        azureEndpoint: String = "",
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
            azureEndpoint = { azureEndpoint },
        )
    }

    private fun ok(body: String) = BatchWire.Response(200, body)

    private fun model(id: String): CloudModel = CloudModel(
        id, id, CloudProvider.forId(id.substringBefore('/')), id.substringAfter('/'), "language",
    )

    @Test
    fun testEveryCatalogueModel_hasATranscriptionRoute() {
        audio.writeBytes(WavFormat.header(2) + ByteArray(2))
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

    @Test
    fun testGladia_pollsUntilDoneAndCancelsAnAbandonedJob() {
        val base = CloudProvider.Gladia.baseUrl
        val gladia = model("gladia/solaria-1")
        val text = transcriber(
            listOf(
                "POST $base/v2/upload" to ok("""{"audio_url":"https://cdn/a"}"""),
                "POST $base/v2/pre-recorded" to ok("""{"id":"j","result_url":"$base/v2/pre-recorded/j"}"""),
                "GET $base/v2/pre-recorded/j" to ok("""{"status":"queued"}"""),
                "GET $base/v2/pre-recorded/j" to ok("""{"status":"done","result":{"transcription":{"full_transcript":"Hi"}}}"""),
            ),
        ).transcribe(gladia, "k", audio, null, CallHandle(), wav, emptyList())
        assertEquals("Hi", text)
        assertEquals(1, pauses)
        assertTrue(sent.all { it.headers["x-gladia-key"] == "k" })

        sent.clear()
        val cancelled = transcriber(
            listOf(
                "POST $base/v2/upload" to ok("""{"audio_url":"https://cdn/a"}"""),
                "POST $base/v2/pre-recorded" to ok("""{"id":"j","result_url":"https://elsewhere/j"}"""),
                "GET $base/v2/pre-recorded/j" to ok("""{"status":"processing"}"""),
                "DELETE $base/v2/pre-recorded/j" to ok(""),
            ),
            pause = BatchPause { _, handle ->
                handle.cancel()
                BatchTranscriber.SLEEP.pause(1, handle)
            },
        )
        assertThrows(CloudException::class.java) {
            cancelled.transcribe(gladia, "k", audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals("DELETE $base/v2/pre-recorded/j", sent.last().let { "${it.method} ${it.url}" })
    }

    @Test
    fun testGemini_uploadsALargeRecordingThroughTheFilesApi() {
        RandomAccessFile(audio, "rw").use { it.setLength(BatchWire.GEMINI_INLINE_BYTES + 1) }
        val base = BatchWire.GEMINI_URL
        val text = transcriber(
            listOf(
                "POST $base/upload/v1beta/files" to BatchWire.Response(200, "{}", mapOf("x-goog-upload-url" to "https://upload/s")),
                "POST https://upload/s" to ok("""{"file":{"name":"files/a","uri":"https://files/a","state":"PROCESSING"}}"""),
                "GET $base/v1beta/files/a" to ok("""{"state":"PROCESSING"}"""),
                "GET $base/v1beta/files/a" to ok("""{"state":"ACTIVE"}"""),
                "POST $base/v1beta/interactions" to ok("""{"output_text":"Hello"}"""),
            ),
        ).transcribe(model("google/gemini-3.5-transcribe"), "k", audio, null, CallHandle(), wav, emptyList())
        assertEquals("Hello", text)
        assertEquals(2, pauses)
        assertTrue(sent.last().body is BatchWire.Body.Json)

        sent.clear()
        val missing = transcriber(listOf("POST $base/upload/v1beta/files" to ok("{}")))
        val error = assertThrows(CloudException::class.java) {
            missing.transcribe(model("google/gemini-3.5-transcribe"), "k", audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals(DictationFailure.Server, error.failure)
    }

    @Test
    fun testMeta_checksTheWavAndMapsItsStatuses() {
        val meta = model("meta/muse-voice-transcribe-1.0")
        val notWav = transcriber(emptyList())
        val unreadable = assertThrows(CloudException::class.java) {
            notWav.transcribe(meta, "k", audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals(DictationFailure.UnsupportedAudio, unreadable.failure)
        assertTrue(sent.isEmpty())

        audio.writeBytes(WavFormat.header(2) + ByteArray(2))
        val rejected = transcriber(listOf("POST ${CloudProvider.Meta.baseUrl}/asr/transcribe" to BatchWire.Response(413, "")))
        val error = assertThrows(CloudException::class.java) {
            rejected.transcribe(meta, "k", audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals(DictationFailure.AudioTooLarge, error.failure)
    }

    @Test
    fun testOpenRouter_refusesWebmAndSendsInklingAsWav() {
        val inkling = CloudCatalog.transcriptionModels.first { it.catalogId == "thinkingmachines/inkling" }
        val webm = SharedAudio.Format("webm", "audio/webm")
        val error = assertThrows(CloudException::class.java) {
            transcriber(emptyList()).transcribe(inkling, "k", audio, null, CallHandle(), webm, emptyList())
        }
        assertEquals(DictationFailure.UnsupportedAudio, error.failure)

        audio.writeBytes(WavFormat.header(2) + ByteArray(2))
        val text = transcriber(
            listOf("POST ${CloudProvider.OpenRouter.baseUrl}/chat/completions" to ok("""{"choices":[{"message":{"content":"Hi"}}]}""")),
        ).transcribe(inkling, "k", audio, null, CallHandle(), wav, emptyList())
        assertEquals("Hi", text)
    }

    @Test
    fun testSmallest_refusesRecordingsOverItsUploadLimit() {
        RandomAccessFile(audio, "rw").use { it.setLength(BatchWire.SMALLEST_MAX_AUDIO_BYTES + 1) }
        val error = assertThrows(CloudException::class.java) {
            transcriber(emptyList()).transcribe(model("smallest/pulse-pro"), "k", audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals(DictationFailure.AudioTooLarge, error.failure)
        assertTrue(sent.isEmpty())
    }

    @Test
    fun testAzure_sendsToTheSavedEndpointAndTakesOnly200AsATranscript() {
        val fast = model(BatchWire.AZURE_FAST)
        audio.writeBytes(WavFormat.header(2) + byteArrayOf(1, 0))
        val endpoint = "https://speak.cognitiveservices.azure.com"
        val url = "POST $endpoint/speechtotext/transcriptions:transcribe"
        val text = transcriber(listOf(url to ok("""{"combinedPhrases":[{"text":" Hello "}]}""")), azureEndpoint = endpoint)
            .transcribe(fast, "secret:westeurope", audio, null, CallHandle(), wav, emptyList())
        assertEquals("Hello", text)
        assertEquals("secret", sent.single().headers["Ocp-Apim-Subscription-Key"])

        val accepted = transcriber(listOf(url to BatchWire.Response(202, "{}")), azureEndpoint = endpoint)
        val error = assertThrows(CloudException::class.java) {
            accepted.transcribe(fast, "secret", audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals(DictationFailure.Server, error.failure)
    }

    @Test
    fun testAzure_refusesALocalProxyTokenAndABadEndpointWithoutSending() {
        audio.writeBytes(WavFormat.header(2) + byteArrayOf(1, 0))
        for ((key, endpoint) in listOf("local-proxy/token" to "", "secret" to "https://example.com")) {
            val error = assertThrows(CloudException::class.java) {
                transcriber(emptyList(), azureEndpoint = endpoint)
                    .transcribe(model(BatchWire.AZURE_FAST), key, audio, null, CallHandle(), wav, emptyList())
            }
            assertEquals(DictationFailure.InvalidKey, error.failure)
        }
        assertTrue(sent.isEmpty())
    }

    private fun alibabaKey(region: AlibabaCredential.Region): String =
        checkNotNull(AlibabaCredential.credentialsForSaving("sk-1", region, "llm-abc"))

    @Test
    fun testAlibaba_neverSendsSilenceAndRefusesARegionTheModelDoesNotServe() {
        val funFlash = model(BatchWire.ALIBABA_FUN_FLASH)
        audio.writeBytes(WavFormat.header(4) + ByteArray(4))
        val silent = transcriber(emptyList())
            .transcribe(funFlash, alibabaKey(AlibabaCredential.Region.Beijing), audio, null, CallHandle(), wav, emptyList())
        assertEquals("", silent)

        val error = assertThrows(CloudException::class.java) {
            transcriber(emptyList()).transcribe(
                funFlash, alibabaKey(AlibabaCredential.Region.Frankfurt), audio, null, CallHandle(), wav, emptyList(),
            )
        }
        assertEquals(DictationFailure.InvalidKey, error.failure)
        assertTrue(sent.isEmpty())
    }

    @Test
    fun testAlibaba_sendsQwenOmniToTheWorkspaceInItsRegion() {
        audio.writeBytes(WavFormat.header(2) + byteArrayOf(1, 0))
        val stream = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hal\"}}]}\n" +
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}]}\n" +
            "data: [DONE]\n"
        val text = transcriber(
            listOf("POST https://llm-abc.eu-central-1.maas.aliyuncs.com/compatible-mode/v1/chat/completions" to ok(stream)),
        ).transcribe(
            model(BatchWire.ALIBABA_QWEN_38),
            alibabaKey(AlibabaCredential.Region.Frankfurt),
            audio,
            "de-DE",
            CallHandle(),
            wav,
            emptyList(),
        )
        assertEquals("Hallo", text)
        assertEquals("Bearer sk-1", sent.single().headers["Authorization"])
    }

    @Test
    fun testStepFun_usesTheKeysRegionAndNeedsAnEventStream() {
        val stepFun = model("stepfun/stepaudio-3-asr-max")
        val key = checkNotNull(StepFunCredential.credentialsForSaving("sk", StepFunCredential.Region.International))
        audio.writeBytes(WavFormat.header(2) + byteArrayOf(1, 0))
        val url = "POST https://api.stepfun.ai/v1/audio/asr/sse"
        val events = mapOf("content-type" to "text/event-stream; charset=utf-8")
        val done = "data: {\"type\":\"transcript.text.done\",\"text\":\" Hi \"}\n\n"
        val text = transcriber(listOf(url to BatchWire.Response(200, done, events)))
            .transcribe(stepFun, key, audio, null, CallHandle(), wav, emptyList())
        assertEquals("Hi", text)

        val notStreamed = assertThrows(CloudException::class.java) {
            transcriber(listOf(url to BatchWire.Response(200, done, mapOf("content-type" to "application/json"))))
                .transcribe(stepFun, key, audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals(DictationFailure.Server, notStreamed.failure)

        val wrongRegion = assertThrows(CloudException::class.java) {
            transcriber(listOf(url to BatchWire.Response(401, "")))
                .transcribe(stepFun, key, audio, null, CallHandle(), wav, emptyList())
        }
        assertEquals(DictationFailure.InvalidKey, wrongRegion.failure)

        val flac = assertThrows(CloudException::class.java) {
            transcriber(emptyList())
                .transcribe(stepFun, key, audio, null, CallHandle(), SharedAudio.Format("flac", "audio/flac"), emptyList())
        }
        assertEquals(DictationFailure.UnsupportedAudio, flac.failure)
    }
}
