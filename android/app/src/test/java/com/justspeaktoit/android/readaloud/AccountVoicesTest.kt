package com.justspeaktoit.android.readaloud

import com.justspeaktoit.android.settings.SettingsSearchAsset
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class AccountVoicesTest {
    private val catalog = VoiceCatalog.parse(SettingsSearchAsset.locate("app/src/main/assets/${VoiceCatalog.ASSET}").readText())

    /** Responds with each status and body in turn. */
    private class FakeHttp(responses: List<Pair<Int, String>>) : SpeechHttp {
        private val queue = ArrayDeque(responses)
        val sent = mutableListOf<SpeechHttpRequest>()
        var unreachable = false

        constructor(vararg bodies: String, status: Int = 200) : this(bodies.map { status to it })

        override suspend fun send(request: SpeechHttpRequest): SpeechHttpResponse {
            sent += request
            if (unreachable) throw IOException("offline")
            val (status, body) = queue.removeFirst()
            return SpeechHttpResponse(status, body.toByteArray())
        }
    }

    /** xAI's built-in listing: the fixed presets and any [extra] built-ins. */
    private fun xaiBuiltIns(vararg extra: String) = JSONObject().put(
        "voices",
        JSONArray((provider("xai").fixedVoiceIds + extra).map { JSONObject().put("voice_id", it) }),
    ).toString()

    private fun provider(id: String) = catalog.accountProviders.first { it.provider == id }

    private fun directory(http: SpeechHttp) = AccountVoiceDirectory(http, ConcurrentHashMap())

    private fun failureOf(block: suspend () -> Unit): ReadAloudFailure = runBlocking {
        try {
            block()
        } catch (error: ReadAloudException) {
            return@runBlocking error.failure
        }
        fail("expected a failure")
        error("unreachable")
    }

    private fun mistralPage(count: Int) = JSONObject().put(
        "items",
        JSONArray(
            (0 until count).map {
                JSONObject().put("id", UUID.randomUUID().toString()).put("name", "Voice $it").put("gender", "FEMALE")
            },
        ),
    ).toString()

    @Test
    fun testCatalog_carriesAccountProvidersAndRealtimeVoices() {
        assertEquals(listOf("mistral", "xai", "soniox"), catalog.accountProviders.map { it.provider })
        val realtime = checkNotNull(catalog.realtime)
        assertTrue(realtime.voices.isNotEmpty())
        val first = realtime.voices.first()
        assertEquals(first, realtime.voice(first.key))
        assertTrue(realtime.url.startsWith("wss://"))
    }

    @Test
    fun testAccountKey_roundTripsThroughTheProviderTemplate() {
        val mistral = provider("mistral")
        val voice = mistral.voice("abc", "Ada")
        assertEquals("abc", mistral.apiVoiceId(voice.key))
        assertEquals(mistral to "abc", catalog.accountVoice(voice.key))
        assertTrue(voice.label.startsWith("Ada"))
        assertNull(catalog.accountVoice("not-a-voice"))
    }

    @Test
    fun testMistral_pagesByOffsetUntilAShortPage() = runBlocking {
        val mistral = provider("mistral")
        val size = checkNotNull(mistral.list.pageSize)
        val http = FakeHttp(mistralPage(size), mistralPage(1))

        val voices = directory(http).voices(mistral, " key ")

        assertEquals(size + 1, voices.size)
        assertEquals(mistral.list.url, http.sent[0].url)
        assertTrue(http.sent[1].url.endsWith("&offset=$size"))
        assertTrue(http.sent.all { it.headers["Authorization"] == "Bearer key" })
        assertTrue(voices.first().label.startsWith("Voice 0 (Female)"))
    }

    @Test
    fun testMistral_invalidIdentifierRejectsTheWholeList() {
        val body = JSONObject().put("items", JSONArray().put(JSONObject().put("id", "nope").put("name", "A"))).toString()
        assertEquals(
            ReadAloudFailure.InvalidVoiceList(provider("mistral").providerName),
            failureOf { directory(FakeHttp(body)).voices(provider("mistral"), "k") },
        )
    }

    @Test
    fun testXai_listsCustomVoicesByPaginationTokenAndNamesUnnamedOnes() = runBlocking {
        val xai = provider("xai")
        val first = JSONObject().put("voices", JSONArray().put(JSONObject().put("voice_id", "my voice")))
            .put("pagination_token", "next page").toString()
        val second = JSONObject().put("voices", JSONArray().put(JSONObject().put("voice_id", "v2").put("name", "Two")))
            .put("pagination_token", JSONObject.NULL).toString()
        val http = FakeHttp(xaiBuiltIns(), first, second)

        val voices = directory(http).voices(xai, "k")

        assertEquals(listOf("My Voice", "Two"), voices.map { it.name })
        assertEquals("my voice", xai.apiVoiceId(voices.first().key))
        assertEquals("https://api.x.ai/v1/tts/voices", http.sent[0].url)
        assertTrue(http.sent[1].url.startsWith("https://api.x.ai/v1/custom-voices?"))
        assertTrue(http.sent[2].url.endsWith("&pagination_token=next%20page"))
        assertTrue(http.sent.all { it.headers["Authorization"] == "Bearer k" })
    }

    @Test
    fun testXai_nonPresetBuiltInsAreListedBeforeCustomVoices() = runBlocking {
        val xai = provider("xai")
        val custom = JSONObject().put("voices", JSONArray().put(JSONObject().put("voice_id", "clone").put("name", "Clone")))
            .toString()

        val voices = directory(FakeHttp(xaiBuiltIns("builtinb"), custom)).voices(xai, "k")

        assertEquals(listOf("builtinb", "clone"), voices.map { xai.apiVoiceId(it.key) })
        assertEquals(listOf("Builtinb", "Clone"), voices.map { it.name })
    }

    @Test
    fun testXai_noCustomLibraryKeepsTheBuiltInsButOtherRefusalsFail() = runBlocking {
        val xai = provider("xai")
        for (absent in listOf(403, 404)) {
            val voices = directory(FakeHttp(listOf(200 to xaiBuiltIns("extra"), absent to "{}"))).voices(xai, "k")
            assertEquals(listOf("extra"), voices.map { xai.apiVoiceId(it.key) })
        }
        // The built-in listing has no absent statuses: a refusal there is the key's.
        assertEquals(
            ReadAloudFailure.KeyRejected(xai.providerName),
            failureOf { directory(FakeHttp("{}", status = 403)).voices(xai, "k") },
        )
        assertEquals(
            ReadAloudFailure.KeyRejected(xai.providerName),
            failureOf { directory(FakeHttp(listOf(200 to xaiBuiltIns(), 401 to "{}"))).voices(xai, "k") },
        )
        val endless = (0..xai.list.maxPages).map { page ->
            JSONObject().put("voices", JSONArray()).put("pagination_token", "t$page").toString()
        }
        assertEquals(
            ReadAloudFailure.InvalidVoiceList(xai.providerName),
            failureOf { directory(FakeHttp(xaiBuiltIns(), *endless.toTypedArray())).voices(xai, "k") },
        )
    }

    @Test
    fun testXai_aCustomVoiceRepeatingABuiltInRejectsTheWholeList() {
        val xai = provider("xai")
        val custom = JSONObject().put("voices", JSONArray().put(JSONObject().put("voice_id", "extra"))).toString()
        assertEquals(
            ReadAloudFailure.InvalidVoiceList(xai.providerName),
            failureOf { directory(FakeHttp(xaiBuiltIns("extra"), custom)).voices(xai, "k") },
        )
    }

    @Test
    fun testSoniox_followsCursorsAndKeepsOnlyReadyVoices() = runBlocking {
        val soniox = provider("soniox")
        fun voice(id: String, status: String) = JSONObject().put("id", id).put("name", id)
            .put("models", JSONArray().put(JSONObject().put("model", soniox.readyModel).put("status", status)))
        val first = JSONObject().put("voices", JSONArray().put(voice("ready_one", "ready")))
            .put("next_page_cursor", "next page").toString()
        val second = JSONObject().put("voices", JSONArray().put(voice("training", "training"))).toString()
        val http = FakeHttp(first, second)

        val voices = directory(http).voices(soniox, "k")

        assertEquals(listOf("ready_one"), voices.map { soniox.apiVoiceId(it.key) })
        assertTrue(http.sent[1].url.endsWith("&cursor=next%20page"))
    }

    @Test
    fun testSoniox_repeatedCursorIsInvalid() {
        val soniox = provider("soniox")
        val page = JSONObject().put("voices", JSONArray()).put("next_page_cursor", "same").toString()
        assertEquals(
            ReadAloudFailure.InvalidVoiceList(soniox.providerName),
            failureOf { directory(FakeHttp(page, page)).voices(soniox, "k") },
        )
    }

    @Test
    fun testSoniox_nonStringCursorIsInvalid() {
        val soniox = provider("soniox")
        val voice = JSONObject().put("id", "ready_one").put("name", "Ready")
            .put("models", JSONArray().put(JSONObject().put("model", soniox.readyModel).put("status", "ready")))
        val page = JSONObject().put("voices", JSONArray().put(voice)).put("next_page_cursor", 17).toString()
        assertEquals(
            ReadAloudFailure.InvalidVoiceList(soniox.providerName),
            failureOf { directory(FakeHttp(page)).voices(soniox, "k") },
        )
    }

    @Test
    fun testListing_mapsRefusalsAndKeepsNoPartialList() {
        val mistral = provider("mistral")
        val name = mistral.providerName
        assertEquals(ReadAloudFailure.KeyRejected(name), failureOf { directory(FakeHttp("{}", status = 401)).voices(mistral, "k") })
        assertEquals(ReadAloudFailure.RateLimited(name), failureOf { directory(FakeHttp("{}", status = 429)).voices(mistral, "k") })
        assertEquals(ReadAloudFailure.MissingKey(name), failureOf { directory(FakeHttp()).voices(mistral, " ") })
        val offline = FakeHttp().apply { unreachable = true }
        assertEquals(ReadAloudFailure.Unreachable(name), failureOf { directory(offline).voices(mistral, "k") })
    }

    @Test
    fun testListing_cachesBySavedKey() = runBlocking {
        val mistral = provider("mistral")
        val directory = directory(FakeHttp(mistralPage(2)))

        directory.voices(mistral, "k")

        assertEquals(2, directory.cached(mistral, "k")?.size)
        assertNull(directory.cached(mistral, "other"))
    }

    @Test
    fun testAccountVoice_fillsTheVoiceIntoItsRequest() = runBlocking {
        val xai = provider("xai")
        val voice = xai.voice("My_Voice", "Mine")
        assertEquals("my_voice", voice.voiceValue)
        val http = object : SpeechHttp {
            var request: SpeechHttpRequest? = null
            override suspend fun send(request: SpeechHttpRequest): SpeechHttpResponse {
                this.request = request
                return SpeechHttpResponse(200, byteArrayOf())
            }
        }
        runCatching { CloudSpeechSynthesizer(http).synthesize(voice, CloudSpeechSynthesizer.Segment("hi", false), "k", "en") }
        val sent = String(checkNotNull(http.request).body)
        assertTrue(sent.contains("my_voice"))
        assertTrue(!sent.contains("{voice}"))
    }
}
