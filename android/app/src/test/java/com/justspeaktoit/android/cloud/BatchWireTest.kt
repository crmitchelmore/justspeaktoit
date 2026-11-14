package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URLDecoder

/** Each provider's request and response format, as its shared SpeakCore client sends and reads it. */
class BatchWireTest {
    private val audio = File("dictation.m4a")
    private val m4a = SharedAudio.Format("m4a", "audio/mp4")
    private val wav = SharedAudio.Format("wav", "audio/wav")

    private fun queryItems(url: String): List<Pair<String, String>> = url.substringAfter('?').split('&').map {
        URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('='), "UTF-8")
    }

    private fun form(request: BatchWire.Request): BatchWire.Body.Form = request.body as BatchWire.Body.Form

    private fun json(request: BatchWire.Request): JSONObject = JSONObject((request.body as BatchWire.Body.Json).text)

    /** The form's text fields in order, file part included as `<file>=filename`. */
    private fun formFields(request: BatchWire.Request): List<Pair<String, String>> {
        val multipart = form(request).multipart
        val text = String(multipart.head) + "<audio>" + String(multipart.tail)
        return text.split("--${multipart.boundary}").drop(1).dropLast(1).map { part ->
            val name = part.substringAfter("name=\"").substringBefore('"')
            if ("filename=\"" in part) {
                "<file:$name>" to part.substringAfter("filename=\"").substringBefore('"')
            } else {
                name to part.substringAfter("\r\n\r\n").removeSuffix("\r\n")
            }
        }
    }

    @Test
    fun testLanguageCode_usesThePrimarySubtagAndLeavesAutomaticOut() {
        assertEquals("en", BatchWire.languageCode("en-GB"))
        assertEquals("pt", BatchWire.languageCode(" PT_br "))
        assertNull(BatchWire.languageCode(null))
        assertNull(BatchWire.languageCode(""))
        assertNull(BatchWire.languageCode("auto"))
    }

    @Test
    fun testKeywordBounds_dropBlankLongAndRepeatedTermsAndRespectTheByteBudget() {
        val words = listOf(" Kubernetes ", "kubernetes", "", "C++", "x".repeat(11))
        assertEquals(listOf("Kubernetes", "C++"), BatchWire.bounded(words, count = 10, length = 10))
        assertEquals(listOf("one"), BatchWire.bounded(listOf("one", "two"), count = 1, length = 10))
        assertEquals(listOf("one", "two"), BatchWire.budgeted(listOf("one", "two", "three"), maxBytes = 8))
        assertEquals(listOf("ok"), BatchWire.budgeted(listOf("é".repeat(4), "ok"), maxBytes = 8))
    }

    @Test
    fun testMultipart_sendsTrailingFieldsAfterTheFile() {
        val parts = CloudWire.multipart(emptyList(), "f", "a.wav", "audio/wav", "B", listOf("x" to "1"))
        assertEquals("\r\n--B\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n1\r\n--B--\r\n", String(parts.tail))
    }

    @Test
    fun testDeepgram_postsRawAudioWithModelLanguageAndKeyterms() {
        val request = BatchWire.deepgram(
            "https://api.deepgram.com/v1", "deepgram/nova-3", "k", audio, m4a, "en-GB", listOf("Kubernetes", "kubernetes"),
        )
        assertEquals("POST", request.method)
        assertTrue(request.url.startsWith("https://api.deepgram.com/v1/listen?"))
        assertEquals(
            listOf(
                "model" to "nova-3", "punctuate" to "true", "numerals" to "true", "utterances" to "true",
                "language" to "en", "keyterm" to "Kubernetes",
            ),
            queryItems(request.url),
        )
        assertEquals(mapOf("Authorization" to "Token k", "Content-Type" to "audio/m4a"), request.headers)
        assertTrue(request.body is BatchWire.Body.Audio)
        assertEquals(listOf("keywords" to "Kubernetes"), BatchWire.deepgramKeywords("nova-2-general", listOf("Kubernetes")))
        assertEquals(emptyList<Pair<String, String>>(), BatchWire.deepgramKeywords("whisper-large", listOf("Kubernetes")))
        assertEquals("nova-3", BatchWire.deepgramModel("deepgram/nova-3-streaming"))
    }

    @Test
    fun testDeepgramText_readsTheFirstAlternative() {
        val body = """{"results":{"channels":[{"alternatives":[{"transcript":" hello there "}]}]}}"""
        assertEquals("hello there", BatchWire.deepgramText(body))
        assertEquals("", BatchWire.deepgramText("""{"results":{"channels":[]}}"""))
    }

    @Test
    fun testAssemblyAI_uploadsThenSubmitsUniversalModelsWithKeyterms() {
        val upload = BatchWire.assemblyAIUpload("https://api.assemblyai.com/v2", "k", audio)
        assertEquals("https://api.assemblyai.com/v2/upload", upload.url)
        assertEquals(mapOf("Authorization" to "k", "Content-Type" to "application/octet-stream"), upload.headers)
        assertEquals("https://cdn/x", BatchWire.assemblyAIUploadUrl("""{"upload_url":"https://cdn/x"}"""))

        val submit = BatchWire.assemblyAISubmit(
            "https://api.assemblyai.com/v2", "assemblyai/universal-3-5-pro", "k", "https://cdn/x", "en-GB", listOf("Kubernetes"),
        )
        assertEquals("https://api.assemblyai.com/v2/transcript", submit.url)
        val body = json(submit)
        assertEquals("https://cdn/x", body.getString("audio_url"))
        assertEquals("[\"universal-3-5-pro\",\"universal-2\"]", body.getJSONArray("speech_models").toString())
        assertEquals("[\"Kubernetes\"]", body.getJSONArray("keyterms_prompt").toString())
        assertEquals("en", body.getString("language_code"))
        assertFalse(body.has("language_detection"))

        val legacy = json(
            BatchWire.assemblyAISubmit("b", "assemblyai/universal-2", "k", "u", null, listOf("Kubernetes")),
        )
        assertEquals("[\"Kubernetes\"]", legacy.getJSONArray("word_boost").toString())
        assertTrue(legacy.getBoolean("language_detection"))
        assertEquals("https://api.assemblyai.com/v2/transcript/a%2Fb", BatchWire.assemblyAIPoll("https://api.assemblyai.com/v2", "k", "a/b").url)
    }

    @Test
    fun testElevenLabs_sendsScribeFieldsAndBoundedKeyterms() {
        val request = BatchWire.elevenLabs(
            "https://api.elevenlabs.io/v1", "elevenlabs/scribe_v2", "k", audio, m4a, "fr-FR",
            listOf("Kubernetes", "<tag>", "one two three four five six"),
        )
        assertEquals("https://api.elevenlabs.io/v1/speech-to-text", request.url)
        assertEquals("k", request.headers["xi-api-key"])
        assertEquals(
            listOf(
                "model_id" to "scribe_v2", "timestamps_granularity" to "word", "language_code" to "fr",
                "keyterms" to "Kubernetes", "<file:file>" to "dictation.m4a",
            ),
            formFields(request),
        )
        assertTrue(String(form(request).multipart.head).contains("Content-Type: audio/m4a"))
        val v1 = BatchWire.elevenLabs("b", "elevenlabs/scribe_v1", "k", audio, wav, null, listOf("Kubernetes"))
        assertTrue(formFields(v1).none { it.first == "keyterms" || it.first == "language_code" })
    }

    @Test
    fun testMistral_biasesOnlyModelsThatTakeContext() {
        val request = BatchWire.mistral(
            "https://api.mistral.ai/v1", "mistral/voxtral-mini-latest", "k", audio, wav, "de-DE", listOf("Kubernetes"),
        )
        assertEquals("https://api.mistral.ai/v1/audio/transcriptions", request.url)
        assertEquals("Bearer k", request.headers["Authorization"])
        assertEquals(
            listOf("model" to "voxtral-mini-latest", "language" to "de", "context_bias" to "Kubernetes", "<file:file>" to "dictation.wav"),
            formFields(request),
        )
        assertTrue(BatchWire.mistralSupportsKeywords("mistral/voxtral-small-transcribe-3-0"))
        assertFalse(BatchWire.mistralSupportsKeywords("mistral/voxtral-mini-2507"))
    }

    @Test
    fun testMistralText_labelsDiarisedSegmentsAndFallsBackToText() {
        val diarised = """{"text":"a b","segments":[{"text":"Hi","speaker":0},{"text":"Hello","speaker":"speaker_1"}]}"""
        assertEquals("Speaker 1: Hi\nSpeaker 2: Hello", BatchWire.mistralText(diarised))
        assertEquals("plain", BatchWire.mistralText("""{"text":"plain","segments":[{"text":"x"}]}"""))
        assertEquals("from segments", BatchWire.mistralText("""{"text":"","segments":[{"text":"from"},{"text":"segments"}]}"""))
        assertEquals("Speaker A", BatchWire.speakerLabel("Speaker A"))
        assertEquals("Alice", BatchWire.speakerLabel("Alice"))
    }

    @Test
    fun testRevAI_submitsMetadataAndJoinsElementValues() {
        val request = BatchWire.revAISubmit("https://api.rev.ai/speechtotext/v1", "k", audio, m4a, "es-ES")
        assertEquals("https://api.rev.ai/speechtotext/v1/jobs", request.url)
        val fields = formFields(request)
        assertEquals("<file:media>" to "dictation.m4a", fields.last())
        val metadata = JSONObject(fields.first().second)
        assertEquals("es", metadata.getString("language"))
        assertFalse(metadata.getBoolean("skip_diarization"))
        assertFalse(metadata.getBoolean("skip_punctuation"))
        assertEquals(
            "application/vnd.rev.transcript.v1.0+json",
            BatchWire.revAITranscript("https://api.rev.ai/speechtotext/v1", "k", "j").headers["Accept"],
        )
        val body = """{"monologues":[{"elements":[{"value":"Hello"},{"value":","},{"value":"world"}]},{"elements":[{"value":"Bye"}]}]}"""
        assertEquals("Hello , world Bye", BatchWire.revAIText(body))
    }

    @Test
    fun testSoniox_createsAFileTranscriptionWithBudgetedTerms() {
        val upload = BatchWire.sonioxUpload("https://api.soniox.com/v1", "k", audio, m4a)
        assertEquals("https://api.soniox.com/v1/files", upload.url)
        assertEquals(listOf("<file:file>" to "dictation.m4a"), formFields(upload))
        assertTrue(String(form(upload).multipart.head).contains("Content-Type: audio/mp4"))

        val body = json(BatchWire.sonioxCreate("https://api.soniox.com/v1", "soniox/stt-async-v4", "k", "f1", "it-IT", listOf("Kubernetes")))
        assertEquals("[\"Kubernetes\"]", body.getJSONObject("context").getJSONArray("terms").toString())
        assertEquals("stt-async-v4", body.getString("model"))
        assertEquals("f1", body.getString("file_id"))
        assertEquals("[\"it\"]", body.getJSONArray("language_hints").toString())
        assertTrue(body.getBoolean("enable_speaker_diarization"))
        assertTrue(body.getBoolean("enable_language_identification"))
        assertFalse(json(BatchWire.sonioxCreate("b", "soniox/x", "k", "f", null, emptyList())).has("context"))
        assertEquals("DELETE", BatchWire.sonioxDelete("b", "k", "files/f").method)
    }

    @Test
    fun testSonioxText_groupsTokensBySpeakerOnlyWhenThereIsMoreThanOne() {
        val one = """{"text":"Hello world","tokens":[{"text":"Hello","speaker":"1"},{"text":" world","speaker":"1"}]}"""
        assertEquals("Hello world", BatchWire.sonioxText(one))
        val two = """{"text":"x","tokens":[{"text":"Hi","speaker":"1"},{"text":" there","speaker":"1"},""" +
            """{"text":"Hola","speaker":"2","language":"es"}]}"""
        assertEquals("Speaker 1: Hi there\nSpeaker 2 [es]: Hola", BatchWire.sonioxText(two))
    }

    @Test
    fun testSpeechmatics_submitsConfigAndDataFile() {
        val request = BatchWire.speechmaticsSubmit(
            "https://eu1.asr.api.speechmatics.com", "speechmatics/enhanced", "k", audio, m4a, null, listOf("Kubernetes"),
        )
        assertEquals("https://eu1.asr.api.speechmatics.com/v2/jobs", request.url)
        val fields = formFields(request)
        assertEquals("<file:data_file>" to "recording.m4a", fields.last())
        val config = JSONObject(fields.first().second)
        assertEquals("transcription", config.getString("type"))
        val transcription = config.getJSONObject("transcription_config")
        assertEquals("auto", transcription.getString("language"))
        assertEquals("enhanced", transcription.getString("operating_point"))
        assertEquals("Kubernetes", transcription.getJSONArray("additional_vocab").getJSONObject(0).getString("content"))
        val standard = JSONObject(BatchWire.speechmaticsConfig("speechmatics/standard", "en-US", emptyList()))
            .getJSONObject("transcription_config")
        assertEquals("standard", standard.getString("operating_point"))
        assertEquals("en", standard.getString("language"))
        assertEquals(
            "https://eu1.asr.api.speechmatics.com/v2/jobs/j/transcript?format=json-v2",
            BatchWire.speechmaticsTranscript("https://eu1.asr.api.speechmatics.com", "k", "j").url,
        )
        assertEquals("https://h/v2/jobs/j?force=true", BatchWire.speechmaticsDelete("https://h", "k", "j").url)
    }

    @Test
    fun testSpeechmaticsStatus_finishesOnDoneAndFailsOnRejection() {
        assertTrue(BatchWire.speechmaticsDone("""{"job":{"status":"done"}}"""))
        assertFalse(BatchWire.speechmaticsDone("""{"job":{"status":"running"}}"""))
        val error = assertThrows(CloudException::class.java) {
            BatchWire.speechmaticsDone("""{"job":{"status":"rejected","errors":[{"message":"bad audio"}]}}""")
        }
        assertEquals(DictationFailure.Server, error.failure)
        assertTrue(error.message.orEmpty().contains("bad audio"))
    }

    @Test
    fun testSpeechmaticsText_attachesPunctuationToTheRightWord() {
        val body = """{"results":[
            {"type":"word","alternatives":[{"content":"Hello"}]},
            {"type":"punctuation","attaches_to":"previous","alternatives":[{"content":","}]},
            {"type":"word","alternatives":[{"content":"world"}]},
            {"type":"punctuation","attaches_to":"next","alternatives":[{"content":"("}]},
            {"type":"word","alternatives":[{"content":"aside"}]},
            {"type":"punctuation","attaches_to":"previous","alternatives":[{"content":")."}]}
        ]}"""
        assertEquals("Hello, world (aside).", BatchWire.speechmaticsText(body))
    }

    @Test
    fun testModulate_sendsFeaturesAfterTheFileOnTheMultilingualModelOnly() {
        val multilingual = BatchWire.modulate("https://platform.modulate.ai", "modulate/velma-2-stt-batch", "k", audio, m4a)
        assertEquals("https://platform.modulate.ai/api/velma-2-stt-batch", multilingual.url)
        assertEquals("k", multilingual.headers["X-API-Key"])
        assertEquals(listOf("<file:upload_file>" to "dictation.m4a") + BatchWire.MODULATE_FEATURES, formFields(multilingual))

        val fast = BatchWire.modulate("https://platform.modulate.ai", "modulate/velma-2-stt-batch-english-vfast", "k", audio, m4a)
        assertEquals("https://platform.modulate.ai/api/velma-2-stt-batch-english-vfast", fast.url)
        assertEquals(listOf("<file:upload_file>" to "dictation.m4a"), formFields(fast))
    }

    @Test
    fun testModulateText_labelsSpeakersWhenThereIsMoreThanOne() {
        val body = """{"text":"Hi Hello","utterances":[{"speaker":1,"text":"Hi"},{"speaker":2,"text":"Hello"}]}"""
        assertEquals("Speaker 1: Hi\nSpeaker 2: Hello", BatchWire.modulateText(body, "modulate/velma-2-stt-batch"))
        assertEquals("Hi Hello", BatchWire.modulateText(body, "modulate/velma-2-stt-batch-english-vfast"))
        assertEquals("solo", BatchWire.modulateText("""{"text":"solo","utterances":[{"speaker":1,"text":"solo"}]}""", "modulate/x"))
    }

    @Test
    fun testReson8_postsRawAudioAndRejectsUnsupportedLanguages() {
        val model = CloudModel(
            "reson8/resonant-1", "Resonant 1", CloudProvider.Reson8, "resonant-1", "language",
            languageCodes = listOf("en", "nl"),
        )
        val request = BatchWire.reson8(model, "k", audio, m4a, "nl-NL")
        assertEquals(
            listOf(
                "model" to "resonant-1", "include_timestamps" to "true", "include_words" to "true",
                "include_confidence" to "true", "language" to "nl", "encoding" to "m4a",
            ),
            queryItems(request.url),
        )
        assertTrue(request.url.startsWith(BatchWire.RESON8_URL + "?"))
        assertEquals("ApiKey k", request.headers["Authorization"])
        assertTrue(request.body is BatchWire.Body.Audio)
        assertTrue(queryItems(BatchWire.reson8(model, "k", audio, wav, null).url).none { it.first in setOf("language", "encoding") })
        val error = assertThrows(CloudException::class.java) { BatchWire.reson8(model, "k", audio, wav, "ja-JP") }
        assertEquals(DictationFailure.LanguageNotSupported, error.failure)
    }

    private fun catalogue(id: String): CloudModel = CloudCatalog.transcriptionModels.first { it.catalogId == id }

    /** A [BatchWire.Body.Base64Json] body as it goes on the wire, parsed. */
    private fun streamedJson(request: BatchWire.Request): JSONObject {
        val body = request.body as BatchWire.Body.Base64Json
        val out = ByteArrayOutputStream()
        body.writeTo(out)
        assertEquals(body.contentLength(), out.size().toLong())
        return JSONObject(out.toString("UTF-8"))
    }

    private fun withFile(bytes: ByteArray, block: (File) -> Unit) {
        val file = File.createTempFile("batch", ".wav")
        try {
            file.writeBytes(bytes)
            block(file)
        } finally {
            file.delete()
        }
    }

    @Test
    fun testBase64Json_streamsTheRecordingInPlaceOfThePlaceholder() {
        for (size in 0..4) {
            val bytes = ByteArray(size) { (it * 37).toByte() }
            withFile(bytes) { file ->
                val request = BatchWire.geminiInline("k", file, wav, null)
                val data = streamedJson(request).getJSONArray("input").getJSONObject(0).getString("data")
                assertEquals(java.util.Base64.getEncoder().encodeToString(bytes), data)
            }
        }
    }

    @Test
    fun testRequirePcm16Wav_acceptsOnlyTheCanonicalRecordingWithinItsLimits() {
        withFile(WavFormat.header(4) + ByteArray(4)) { BatchWire.requirePcm16Wav(it, maxSeconds = 1, maxBytes = 1_000) }
        val cases = listOf(
            ByteArray(10) to DictationFailure.UnsupportedAudio,
            WavFormat.header(0) to DictationFailure.NoSpeech,
            WavFormat.header(3) + ByteArray(3) to DictationFailure.UnsupportedAudio,
            WavFormat.header(8) + ByteArray(4) to DictationFailure.UnsupportedAudio,
            WavFormat.header(64_002) + ByteArray(64_002) to DictationFailure.AudioTooLarge,
        )
        for ((bytes, failure) in cases) {
            withFile(bytes) { file ->
                val error = assertThrows(CloudException::class.java) {
                    BatchWire.requirePcm16Wav(file, maxSeconds = 2, maxBytes = 1_000_000)
                }
                assertEquals(failure, error.failure)
            }
        }
        withFile(WavFormat.header(4) + ByteArray(4)) { file ->
            val error = assertThrows(CloudException::class.java) { BatchWire.requirePcm16Wav(file, 1, maxBytes = 48) }
            assertEquals(DictationFailure.AudioTooLarge, error.failure)
        }
    }

    @Test
    fun testIsSameOrigin_matchesSchemeHostAndDefaultPorts() {
        assertTrue(BatchWire.isSameOrigin("https://API.gladia.io:443/v2/x", "https://api.gladia.io"))
        assertFalse(BatchWire.isSameOrigin("http://api.gladia.io/v2/x", "https://api.gladia.io"))
        assertFalse(BatchWire.isSameOrigin("https://api.gladia.io:8443/v2/x", "https://api.gladia.io"))
        assertFalse(BatchWire.isSameOrigin("https://evil.example/v2/x", "https://api.gladia.io"))
        assertFalse(BatchWire.isSameOrigin("not a url", "https://api.gladia.io"))
    }

    @Test
    fun testCartesia_sendsTheVersionedFormAndReadsATranscript() {
        val request = BatchWire.cartesia(catalogue("cartesia/ink-whisper"), "k", audio, m4a, "pt-BR")
        assertEquals("https://api.cartesia.ai/stt", request.url)
        assertEquals("Bearer k", request.headers["Authorization"])
        assertEquals(BatchWire.CARTESIA_VERSION, request.headers["Cartesia-Version"])
        assertEquals(
            listOf("model" to "ink-whisper", "language" to "pt", "timestamp_granularities[]" to "word", "<file:file>" to "recording.m4a"),
            formFields(request),
        )
        assertTrue(formFields(BatchWire.cartesia(catalogue("cartesia/ink-whisper"), "k", audio, m4a, null)).none { it.first == "language" })
        assertEquals("Hi", BatchWire.cartesiaText("""{"type":"transcript","text":" Hi "}"""))
        assertThrows(CloudException::class.java) { BatchWire.cartesiaText("""{"type":"error","text":"Hi"}""") }
    }

    @Test
    fun testSmallest_postsEnglishRawAudioAndRejectsOtherLanguages() {
        val model = catalogue("smallest/pulse-pro")
        val request = BatchWire.smallest(model, "k", audio, "en-GB")
        assertTrue(request.url.startsWith("https://api.smallest.ai/waves/v1/stt/?"))
        assertEquals(
            listOf("model" to "pulse-pro", "language" to "en", "word_timestamps" to "true"),
            queryItems(request.url),
        )
        assertEquals("Bearer k", request.headers["Authorization"])
        assertEquals("application/octet-stream", request.headers["Content-Type"])
        assertTrue(request.body is BatchWire.Body.Audio)
        assertEquals(queryItems(request.url), queryItems(BatchWire.smallest(model, "k", audio, null).url))
        val error = assertThrows(CloudException::class.java) { BatchWire.smallest(model, "k", audio, "fr-FR") }
        assertEquals(DictationFailure.LanguageNotSupported, error.failure)
        assertEquals("Hello", BatchWire.smallestText("""{"status":"success","transcription":"Hello"}"""))
        assertThrows(CloudException::class.java) { BatchWire.smallestText("""{"status":"failed","transcription":"x"}""") }
    }

    @Test
    fun testXAI_formatsOnlyAListedLanguageAndSendsKeyterms() {
        val model = catalogue("xai/speech-to-text")
        val request = BatchWire.xai(model, "k", audio, m4a, "de-DE", listOf(" Kubernetes ", "", "x".repeat(51)))
        assertEquals("https://api.x.ai/v1/stt", request.url)
        assertEquals("Bearer k", request.headers["Authorization"])
        assertEquals(
            listOf(
                "model" to "grok-voice-transcribe-2.0", "language" to "de", "format" to "true",
                "keyterm" to "Kubernetes", "<file:file>" to "recording.m4a",
            ),
            formFields(request),
        )
        val automatic = formFields(BatchWire.xai(model, "k", audio, m4a, "zz-ZZ", emptyList()))
        assertTrue(automatic.none { it.first == "language" || it.first == "format" })
        val webm = SharedAudio.Format("webm", "audio/webm")
        val error = assertThrows(CloudException::class.java) { BatchWire.xai(model, "k", audio, webm, null, emptyList()) }
        assertEquals(DictationFailure.UnsupportedAudio, error.failure)
        assertEquals(100, BatchWire.xaiKeyterms(List(120) { "t$it" }).size)
    }

    @Test
    fun testXAIText_fallsBackFromTextToChannelsToWords() {
        assertEquals("Hi", BatchWire.xaiText("""{"text":" Hi "}"""))
        assertEquals("a\nb", BatchWire.xaiText("""{"text":"","channels":[{"text":"a"},{"text":"b"}]}"""))
        assertEquals("one two", BatchWire.xaiText("""{"words":[{"text":"one"},{"text":"two"}]}"""))
        assertEquals("", BatchWire.xaiText("{}"))
    }

    @Test
    fun testGladia_uploadsSubmitsAndPinsOnlyAListedLanguage() {
        val model = catalogue("gladia/solaria-1")
        val upload = BatchWire.gladiaUpload(model.provider.baseUrl, "k", audio, m4a)
        assertEquals("https://api.gladia.io/v2/upload", upload.url)
        assertEquals("k", upload.headers["x-gladia-key"])
        assertEquals(listOf("<file:audio>" to "recording.m4a"), formFields(upload))

        val submit = BatchWire.gladiaSubmit(model, "k", "https://cdn/a", "fr-CA")
        assertEquals("https://api.gladia.io/v2/pre-recorded", submit.url)
        val body = json(submit)
        assertEquals("https://cdn/a", body.getString("audio_url"))
        assertEquals("solaria-1", body.getString("model"))
        assertEquals("fr", body.getJSONObject("language_config").getJSONArray("languages").getString(0))
        assertFalse(body.getJSONObject("language_config").getBoolean("code_switching"))
        val detect = json(BatchWire.gladiaSubmit(model, "k", "https://cdn/a", null)).getJSONObject("language_config")
        assertEquals(0, detect.getJSONArray("languages").length())
        assertTrue(detect.getBoolean("code_switching"))
    }

    @Test
    fun testGladiaJob_pollsTheResultUrlOnlyOnGladiasOrigin() {
        val base = CloudProvider.Gladia.baseUrl
        assertEquals("$base/v2/pre-recorded/j1?x=1", BatchWire.gladiaJob("""{"id":"j1","result_url":"$base/v2/pre-recorded/j1?x=1"}""", base).resultUrl)
        assertEquals("$base/v2/pre-recorded/j%201", BatchWire.gladiaJob("""{"id":"j 1","result_url":"https://elsewhere/j"}""", base).resultUrl)
        assertThrows(CloudException::class.java) { BatchWire.gladiaJob("""{"result_url":"https://elsewhere/j"}""", base) }
        assertThrows(CloudException::class.java) { BatchWire.gladiaAudioUrl("""{"audio_url":""}""") }
    }

    @Test
    fun testGladiaResult_readsTheTranscriptOnceDone() {
        assertNull(BatchWire.gladiaResult("""{"status":"processing"}"""))
        assertEquals("Hi", BatchWire.gladiaResult("""{"status":"done","result":{"transcription":{"full_transcript":"Hi"}}}"""))
        assertEquals(
            "a b",
            BatchWire.gladiaResult("""{"status":"done","result":{"transcription":{"utterances":[{"text":"a"},{"text":"b"}]}}}"""),
        )
        assertThrows(CloudException::class.java) { BatchWire.gladiaResult("""{"status":"error","error_code":500}""") }
    }

    @Test
    fun testMeta_sendsTheRequestPartBeforeTheWav() {
        val model = catalogue("meta/muse-voice-transcribe-1.0")
        val request = BatchWire.meta(model, "k", audio, "de-DE", listOf("Kubernetes", "kubernetes"))
        assertEquals("https://api.meta.ai/v1/asr/transcribe", request.url)
        assertEquals("Bearer k", request.headers["Authorization"])
        val multipart = form(request).multipart
        val head = String(multipart.head)
        assertTrue(head.contains("name=\"audio\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav"))
        val settings = JSONObject(head.substringAfter("application/json\r\n\r\n").substringBefore("\r\n"))
        assertEquals("WAV", settings.getString("audioEncoding"))
        assertEquals("ENDPOINTING", settings.getString("mode"))
        assertEquals("muse-voice-transcribe-1.0", settings.getString("model"))
        assertEquals(1, settings.getJSONArray("keywords").length())
        assertEquals("German", settings.getJSONArray("languageBias").getString(0))
        val plain = BatchWire.meta(model, "k", audio, null, emptyList())
        assertFalse(String(form(plain).multipart.head).contains("keywords"))
        assertFalse(String(form(plain).multipart.head).contains("languageBias"))
        assertEquals(DictationFailure.UnsupportedAudio, BatchWire.metaFailure(415))
        assertEquals(DictationFailure.AudioTooLarge, BatchWire.metaFailure(413))
        assertEquals(DictationFailure.InvalidKey, BatchWire.metaFailure(401))
        assertEquals("Hi", BatchWire.metaText("""{"transcript":"Hi"}"""))
    }

    @Test
    fun testGemini_sendsAVerbatimInteractionWithTheLanguage() {
        withFile(byteArrayOf(1, 2, 3)) { file ->
            val request = BatchWire.geminiInline("k", file, m4a, "en_GB")
            assertEquals("${BatchWire.GEMINI_URL}/v1beta/interactions", request.url)
            assertEquals("k", request.headers["x-goog-api-key"])
            val body = streamedJson(request)
            assertEquals("gemini-3.5-transcribe", body.getString("model"))
            val input = body.getJSONArray("input").getJSONObject(0)
            assertEquals("audio", input.getString("type"))
            assertEquals("audio/m4a", input.getString("mime_type"))
            val config = body.getJSONObject("generation_config").getJSONObject("transcription_config")
            assertEquals("en-GB", config.getJSONArray("language_codes").getString(0))
            assertEquals("verbatim", config.getJSONObject("mode").getString("type"))
            assertEquals("speaker", config.getJSONObject("mode").getString("diarization_mode"))
        }
        val fromFile = json(BatchWire.geminiFromFile("k", "https://files/a", wav, null))
        assertEquals("https://files/a", fromFile.getJSONArray("input").getJSONObject(0).getString("uri"))
        assertEquals(0, fromFile.getJSONObject("generation_config").getJSONObject("transcription_config").getJSONArray("language_codes").length())
    }

    @Test
    fun testGeminiFiles_startTheUploadAndReadTheFileState() {
        val start = BatchWire.geminiUploadStart("k", audio, m4a)
        assertEquals("${BatchWire.GEMINI_URL}/upload/v1beta/files", start.url)
        assertEquals("resumable", start.headers["X-Goog-Upload-Protocol"])
        assertEquals("start", start.headers["X-Goog-Upload-Command"])
        assertEquals("audio/m4a", start.headers["X-Goog-Upload-Header-Content-Type"])
        val upload = BatchWire.geminiUpload("https://upload/session", audio, m4a)
        assertNull(upload.headers["x-goog-api-key"])
        assertEquals("upload, finalize", upload.headers["X-Goog-Upload-Command"])
        val file = BatchWire.geminiUploadedFile("""{"file":{"name":"files/a","uri":"https://files/a","state":"PROCESSING"}}""")
        assertEquals("https://files/a", file.uri)
        assertEquals("${BatchWire.GEMINI_URL}/v1beta/files/a%20b", BatchWire.geminiFileStatus("k", "a b").url)
        assertEquals("ACTIVE", BatchWire.geminiFileState("""{"file":{"state":"ACTIVE"}}"""))
        assertEquals("Hello world", BatchWire.geminiText("""{"steps":[{"content":[{"text":"Hello"},{"text":"world"}]}]}"""))
        assertEquals("Hi", BatchWire.geminiText("""{"output_text":" Hi "}"""))
    }

    @Test
    fun testOpenRouter_sendsTheRecordingInlineToTheFullModelSlug() {
        val model = catalogue("google/gemini-2.5-flash")
        assertEquals(CloudProvider.OpenRouter, model.provider)
        withFile(byteArrayOf(9, 8, 7)) { file ->
            val request = BatchWire.openRouter(model, "k", file, "m4a", "fr-FR")
            assertEquals("https://openrouter.ai/api/v1/chat/completions", request.url)
            assertEquals("Bearer k", request.headers["Authorization"])
            val body = streamedJson(request)
            assertEquals("google/gemini-2.5-flash", body.getString("model"))
            assertFalse(body.getBoolean("stream"))
            val content = body.getJSONArray("messages").getJSONObject(0).getJSONArray("content")
            assertTrue(content.getJSONObject(0).getString("text").contains("locale fr-FR"))
            val inputAudio = content.getJSONObject(1).getJSONObject("input_audio")
            assertEquals("m4a", inputAudio.getString("format"))
            assertEquals("CQgH", inputAudio.getString("data"))
        }
        assertNull(BatchWire.openRouterFormat(SharedAudio.Format("webm", "audio/webm")))
        assertNotNull(BatchWire.openRouterFormat(wav))
        assertEquals("Hi", BatchWire.openRouterText("""{"choices":[{"message":{"content":" Hi "}}]}"""))
        assertThrows(CloudException::class.java) { BatchWire.openRouterText("""{"choices":[]}""") }
    }

    @Test
    fun testParsers_reportAMalformedResponseAsAServerFailure() {
        for (parse in listOf<(String) -> String>(BatchWire::deepgramText, BatchWire::revAIText, BatchWire::speechmaticsText)) {
            assertEquals(DictationFailure.Server, assertThrows(CloudException::class.java) { parse("not json") }.failure)
        }
        assertEquals(
            DictationFailure.Server,
            assertThrows(CloudException::class.java) { BatchWire.requiredString("""{"text":null}""", "text") }.failure,
        )
    }

    @Test
    fun testAzure_postsTheDefinitionThenTheRecordingToTheRegionalOrigin() {
        val connection = AzureSpeechCredential.connection("secret:WestEurope", "")
        val request = BatchWire.azure(connection, catalogue(BatchWire.AZURE_MAI_2), audio, "en_GB", listOf(" Kubectl "))
        assertEquals(
            "https://westeurope.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15",
            request.url,
        )
        assertEquals("secret", request.headers["Ocp-Apim-Subscription-Key"])
        val fields = formFields(request)
        assertEquals(listOf("definition", "<file:audio>"), fields.map { it.first })
        assertEquals("recording.wav", fields[1].second)
        assertTrue("Content-Type: audio/wav" in String(form(request).multipart.head))
        val definition = JSONObject(fields[0].second)
        assertEquals("MAI-Transcribe-2", definition.getJSONObject("enhancedMode").getString("model"))
        assertTrue(definition.getJSONObject("enhancedMode").getBoolean("enabled"))
        assertEquals("en-GB", definition.getJSONArray("locales").getString(0))
        assertEquals("Kubectl", definition.getJSONObject("phraseList").getJSONArray("phrases").getString(0))

        assertEquals("{}", BatchWire.azureDefinition(BatchWire.AZURE_FAST, "auto", emptyList()).toString())
        assertEquals(
            "MAI-Transcribe-1.5",
            BatchWire.azureDefinition("azure/mai-transcribe-1.5", null, emptyList())
                .getJSONObject("enhancedMode").getString("model"),
        )
    }

    @Test
    fun testAzureText_prefersCombinedPhrasesAndNeedsOneOrTheOther() {
        assertEquals("One two", BatchWire.azureText("""{"combinedPhrases":[{"text":"One two"}],"phrases":[{"text":"x"}]}"""))
        assertEquals("One two", BatchWire.azureText("""{"phrases":[{"text":"One"},{"text":"two"}]}"""))
        assertEquals("", BatchWire.azureText("""{"combinedPhrases":[]}"""))
        for (body in listOf("{}", """{"phrases":[{"text":1}]}""", "not json")) {
            assertEquals(
                DictationFailure.Server,
                assertThrows(CloudException::class.java) { BatchWire.azureText(body) }.failure,
            )
        }
    }

    private fun alibaba(region: AlibabaCredential.Region = AlibabaCredential.Region.Singapore) =
        checkNotNull(AlibabaCredential.parse(checkNotNull(AlibabaCredential.credentialsForSaving("sk-1", region, "llm-abc"))))

    @Test
    fun testAlibaba_sendsFunAsrToTheGenerationEndpointWithTheWavInline() {
        val bytes = byteArrayOf(1, 2, 3, 4, 5)
        withFile(bytes) { file ->
            val request = BatchWire.alibaba(alibaba(), catalogue(BatchWire.ALIBABA_FUN_FLASH), file, "en")
            assertEquals(
                "https://llm-abc.ap-southeast-1.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
                request.url,
            )
            assertEquals("Bearer sk-1", request.headers["Authorization"])
            assertEquals("disable", request.headers["X-DashScope-SSE"])
            val json = streamedJson(request)
            assertEquals("fun-asr-flash-2026-06-15", json.getString("model"))
            assertEquals("wav", json.getJSONObject("parameters").getString("format"))
            val input = json.getJSONObject("input").getJSONArray("messages").getJSONObject(0)
                .getJSONArray("content").getJSONObject(0)
            assertEquals("input_audio", input.getString("type"))
            assertEquals(
                "data:audio/wav;base64," + java.util.Base64.getEncoder().encodeToString(bytes),
                input.getJSONObject("input_audio").getString("data"),
            )
        }
    }

    @Test
    fun testAlibaba_streamsQwenOmniWithThePromptAndOnlyQwen38SkipsReasoning() {
        withFile(byteArrayOf(9, 8, 7)) { file ->
            val qwen38 = BatchWire.alibaba(alibaba(), catalogue(BatchWire.ALIBABA_QWEN_38), file, "fr-FR")
            assertEquals("https://llm-abc.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/chat/completions", qwen38.url)
            assertNull(qwen38.headers["X-DashScope-SSE"])
            val json = streamedJson(qwen38)
            assertTrue(json.getBoolean("stream"))
            assertTrue(json.getJSONObject("stream_options").getBoolean("include_usage"))
            assertEquals("none", json.getString("reasoning_effort"))
            assertEquals("text", json.getJSONArray("modalities").getString(0))
            val content = json.getJSONArray("messages").getJSONObject(0).getJSONArray("content")
            assertTrue(content.getJSONObject(0).getString("text").endsWith("hint is fr; preserve the original language."))
            assertEquals("data:audio/wav;base64,CQgH", content.getJSONObject(1).getJSONObject("input_audio").getString("data"))

            val plus = BatchWire.alibaba(alibaba(), catalogue("alibaba/qwen3.5-omni-plus"), file, null)
            assertFalse(streamedJson(plus).has("reasoning_effort"))
        }
        assertFalse(BatchWire.alibabaSupportsRegion(BatchWire.ALIBABA_FUN_FLASH, AlibabaCredential.Region.Virginia))
        assertTrue(BatchWire.alibabaSupportsRegion(BatchWire.ALIBABA_QWEN_38, AlibabaCredential.Region.Virginia))
        assertTrue(BatchWire.alibabaSupportsRegion("alibaba/qwen3.5-omni-plus", AlibabaCredential.Region.Beijing))
    }

    @Test
    fun testAlibabaText_readsFunAsrAndConfirmedOmniStreams() {
        assertEquals("Hi", BatchWire.alibabaFunText("""{"output":{"text":" Hi "}}"""))
        assertEquals("Hi", BatchWire.alibabaFunText("""{"output":{"output":{"sentence":{"text":"Hi"}}}}"""))
        assertEquals(
            DictationFailure.Server,
            assertThrows(CloudException::class.java) {
                BatchWire.alibabaFunText("""{"code":"InvalidParameter","output":{"text":"x"}}""")
            }.failure,
        )
        val chunk = { index: Int, text: String, reason: String? ->
            val finish = reason?.let { ",\"finish_reason\":\"$it\"" }.orEmpty()
            "data: {\"choices\":[{\"index\":$index,\"delta\":{\"content\":\"$text\"}$finish}]}"
        }
        val stream = listOf(chunk(0, "One ", null), chunk(1, "ignored", null), chunk(0, "two", "stop"), "data: [DONE]")
        assertEquals("One two", BatchWire.alibabaOmniText(stream.joinToString("\n")))
        for (unfinished in listOf(chunk(0, "One", null), chunk(0, "One", "length"), "data: {\"error\":{}}")) {
            assertEquals(
                DictationFailure.Server,
                assertThrows(CloudException::class.java) { BatchWire.alibabaOmniText(unfinished) }.failure,
            )
        }
    }

    @Test
    fun testStepFun_postsBase64ToTheKeysRegionalEndpoint() {
        val international = checkNotNull(
            StepFunCredential.parse(checkNotNull(StepFunCredential.credentialsForSaving("sk", StepFunCredential.Region.International))),
        )
        withFile(byteArrayOf(1, 2, 3)) { file ->
            val request = BatchWire.stepFun(international, file, "wav", "en-GB")
            assertEquals("https://api.stepfun.ai/v1/audio/asr/sse", request.url)
            assertEquals("Bearer sk", request.headers["Authorization"])
            assertEquals("text/event-stream", request.headers["Accept"])
            val audioJson = streamedJson(request).getJSONObject("audio")
            assertEquals("AQID", audioJson.getString("data"))
            val input = audioJson.getJSONObject("input")
            assertEquals("wav", input.getJSONObject("format").getString("type"))
            val transcription = input.getJSONObject("transcription")
            assertEquals("stepaudio-3-asr-max", transcription.getString("model"))
            assertEquals("en", transcription.getString("language"))
            assertTrue(transcription.getBoolean("enable_itn"))

            val china = checkNotNull(StepFunCredential.parse("legacy-key"))
            assertEquals("https://api.stepfun.com/v1/audio/asr/sse", BatchWire.stepFun(china, file, "m4a", null).url)
        }
        assertEquals("m4a", BatchWire.stepFunFormat(m4a))
        assertNull(BatchWire.stepFunFormat(SharedAudio.Format("webm", "audio/webm")))
    }

    @Test
    fun testStepFunText_takesTheDoneEventAndFailsOnErrorsOrAnUnfinishedStream() {
        val stream = "data: {\"type\":\"transcript.text.delta\",\"delta\":\"He\"}\r\n\r\n" +
            "data: {\"type\":\"transcript.text.done\",\"text\":\" Hello \"}\n\ndata: [DONE]\n\n"
        assertEquals("Hello", BatchWire.stepFunText(stream))
        val error = "data: {\"type\":\"error\",\"message\":\"quota\"}\n\n"
        val unfinished = "data: {\"type\":\"transcript.text.delta\",\"delta\":\"He\"}\n\n"
        for (body in listOf(error, unfinished)) {
            assertEquals(
                DictationFailure.Server,
                assertThrows(CloudException::class.java) { BatchWire.stepFunText(body) }.failure,
            )
        }
        val streamed = BatchWire.Response(200, "", mapOf("content-type" to "Text/Event-Stream; charset=utf-8"))
        assertTrue(BatchWire.isEventStream(streamed))
        assertFalse(BatchWire.isEventStream(BatchWire.Response(200, "", mapOf("content-type" to "application/json"))))
        assertFalse(BatchWire.isEventStream(BatchWire.Response(200, "")))
    }
}
