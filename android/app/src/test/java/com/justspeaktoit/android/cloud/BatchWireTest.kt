package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
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
}
