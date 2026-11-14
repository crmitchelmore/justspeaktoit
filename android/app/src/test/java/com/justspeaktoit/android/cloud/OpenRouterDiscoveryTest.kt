package com.justspeaktoit.android.cloud

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import kotlin.coroutines.CoroutineContext

/**
 * Live OpenRouter discovery against SpeakCore's rules: the cleanup filter against the fixture the Swift
 * tests share (`Tests/Fixtures/openrouter-browser/cleanup-discovery.json`), the transcription filter,
 * the caches and the store's fallback to the cache and bundled models.
 */
class OpenRouterDiscoveryTest {
    @get:Rule val folder = TemporaryFolder()

    /** Runs nothing until [drain], so each test steps the main and io lanes itself. */
    private class QueueDispatcher : CoroutineDispatcher() {
        private val queue = ArrayDeque<Runnable>()

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            queue.addLast(block)
        }

        fun drain() {
            while (queue.isNotEmpty()) queue.removeFirst().run()
        }
    }

    private val transcriptionBody = """
        {"data": [
          {"id": "openai/whisper-large-v3", "name": "Whisper Large v3", "description": "Speech to text",
           "architecture": {"input_modalities": ["audio"], "output_modalities": ["transcription"]},
           "pricing": {"audio": "0.0001", "request": "0"}, "context_length": 448},
          {"id": "openai/whisper-large-v3", "name": "Duplicate",
           "architecture": {"input_modalities": ["audio"], "output_modalities": ["transcription"]}},
          {"id": "vendor/voice", "name": "Voice",
           "architecture": {"input_modalities": ["text"], "output_modalities": ["speech"]}},
          {"id": "vendor/chat", "name": "Chat",
           "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]}},
          {"id": "bad id", "name": "Bad",
           "architecture": {"input_modalities": ["audio"], "output_modalities": ["transcription"]}},
          {"id": "vendor/no-architecture", "name": "No architecture"},
          {"id": "vendor/free", "name": "",
           "architecture": {"input_modalities": ["audio"], "output_modalities": ["transcription"]},
           "pricing": {"audio": "0", "request": "0.0", "note": 5}, "context_length": 0}
        ]}
    """.trimIndent()

    @Test
    fun testParseCleanup_matchesTheSharedFixture() {
        val fixture = JSONObject(RepoSources.fixture("openrouter-browser/cleanup-discovery.json"))
        val expected = fixture.getJSONArray("expected").let { array ->
            (0 until array.length()).map { index ->
                val row = array.getJSONObject(index)
                fun number(key: String): Double? = if (row.isNull(key)) null else row.getDouble(key)
                DiscoveredCleanupModel(
                    id = row.getString("id"),
                    name = row.getString("name"),
                    inputPrice = number("inputPrice"),
                    outputPrice = number("outputPrice"),
                    contextLength = number("contextLength")?.toInt(),
                )
            }
        }
        assertEquals(expected, OpenRouterDiscovery.parseCleanup(fixture.getJSONObject("response").toString()))
    }

    @Test
    fun testParseCleanup_rejectsAResponseWithoutAModelList() {
        for (body in listOf("not json", "{}", """{"data": {}}""")) {
            assertThrows(OpenRouterDiscoveryException::class.java) { OpenRouterDiscovery.parseCleanup(body) }
        }
        assertEquals(emptyList<DiscoveredCleanupModel>(), OpenRouterDiscovery.parseCleanup("""{"data": []}"""))
    }

    @Test
    fun testParseTranscription_keepsAudioModelsOnceAndSkipsUnreadableEntries() {
        val models = OpenRouterDiscovery.parseTranscription(transcriptionBody)
        assertEquals(listOf("openai/whisper-large-v3", "vendor/voice", "vendor/free"), models.map { it.id })
        val whisper = models.first()
        assertEquals("Whisper Large v3", whisper.name)
        assertEquals(448, whisper.contextLength)
        assertTrue(whisper.supportsTranscription)
        assertEquals("openrouter/transcription/openai/whisper-large-v3", whisper.transcriptionSelectionId)
        assertFalse(models[1].supportsTranscription)
        val free = models[2]
        assertEquals("vendor/free", free.name)
        assertNull(free.contextLength)
        assertEquals(mapOf("audio" to "0", "request" to "0.0"), free.pricing)
        assertTrue(OpenRouterDiscovery.hasZeroPrices(free.pricing))
        assertFalse(OpenRouterDiscovery.hasZeroPrices(whisper.pricing))
        assertFalse(OpenRouterDiscovery.hasZeroPrices(emptyMap()))
    }

    @Test
    fun testParseTranscription_rejectsAListWithNothingUsableSoTheCacheIsKept() {
        val ignoredFilter = """{"data": [{"id": "vendor/chat", "name": "Chat",
            "architecture": {"input_modalities": ["text"], "output_modalities": ["text"]}}]}"""
        assertThrows(OpenRouterDiscoveryException::class.java) { OpenRouterDiscovery.parseTranscription(ignoredFilter) }
        assertEquals(emptyList<OpenRouterAudioModel>(), OpenRouterDiscovery.parseTranscription("""{"data": []}"""))
    }

    @Test
    fun testCaches_roundTripAndIgnoreExpiredFutureDatedAndOtherVersions() {
        val now = 10L * OpenRouterDiscovery.MAX_CACHE_AGE_MILLIS
        val audio = OpenRouterDiscovery.parseTranscription(transcriptionBody)
        val cleanup = listOf(DiscoveredCleanupModel("openai/gpt-future", "GPT Future", 0.1, 0.5, 1_050_000))

        val transcription = OpenRouterDiscovery.encodeTranscriptionCache(audio, now - 1)
        assertEquals(OpenRouterDiscovery.Cached(audio, now - 1), OpenRouterDiscovery.decodeTranscriptionCache(transcription, now))
        val cleanupCache = OpenRouterDiscovery.encodeCleanupCache(cleanup, now - 1)
        assertEquals(OpenRouterDiscovery.Cached(cleanup, now - 1), OpenRouterDiscovery.decodeCleanupCache(cleanupCache, now))

        val expired = OpenRouterDiscovery.encodeCleanupCache(cleanup, now - OpenRouterDiscovery.MAX_CACHE_AGE_MILLIS - 1)
        assertNull(OpenRouterDiscovery.decodeCleanupCache(expired, now))
        assertNull(OpenRouterDiscovery.decodeTranscriptionCache(transcription, now - 2))
        val otherVersion = JSONObject(cleanupCache).put("version", 2).toString()
        assertNull(OpenRouterDiscovery.decodeCleanupCache(otherVersion, now))
        assertNull(OpenRouterDiscovery.decodeCleanupCache("not json", now))
    }

    @Test
    fun testCleanupCache_dropsRowsThatAreNotTrustedOpenAIModels() {
        val text = OpenRouterDiscovery.encodeCleanupCache(
            listOf(
                DiscoveredCleanupModel("openai/gpt-future", "GPT Future", null, null, null),
                DiscoveredCleanupModel("anthropic/claude", "Claude", null, null, null),
                DiscoveredCleanupModel("openai/../evil", "Evil", null, null, null),
            ),
            updatedAt = 1,
        )
        assertEquals(listOf("openai/gpt-future"), OpenRouterDiscovery.decodeCleanupCache(text, 2)?.models?.map { it.id })
    }

    @Test
    fun testMissingTranscriptionSelection_isKnownOnlyOnceALiveCatalogueLoaded() {
        val models = OpenRouterDiscovery.parseTranscription(transcriptionBody)
        val saved = "openrouter/transcription/vendor/retired"
        assertNull(OpenRouterDiscovery.missingTranscriptionSelection(saved, models, catalogueLoaded = false))
        assertEquals("vendor/retired", OpenRouterDiscovery.missingTranscriptionSelection(saved, models, true))
        assertNull(OpenRouterDiscovery.missingTranscriptionSelection(models.first().transcriptionSelectionId, models, true))
        assertNull(OpenRouterDiscovery.missingTranscriptionSelection("google/gemini-2.5-flash", models, true))
    }

    @Test
    fun testSelections_acceptOnlyTheirOwnNamespace() {
        assertEquals("openai/gpt-future", OpenRouterCleanupSelection.modelId("openrouter/cleanup/openai/gpt-future"))
        assertNull(OpenRouterCleanupSelection.modelId("openrouter/cleanup/anthropic/claude"))
        assertNull(OpenRouterCleanupSelection.modelId("openrouter/cleanup/openai/Upper"))
        assertNull(OpenRouterCleanupSelection.modelId("openai/gpt-future"))
        assertEquals("a/b/c", OpenRouterTranscriptionSelection.modelId("openrouter/transcription/a/b/c"))
        assertNull(OpenRouterTranscriptionSelection.modelId("openrouter/transcription/single"))
        assertNull(OpenRouterTranscriptionSelection.modelId("openrouter/transcription/a/ b"))
    }

    // region Store

    private val main = QueueDispatcher()
    private val io = QueueDispatcher()
    private var now = 100L * OpenRouterDiscovery.MAX_CACHE_AGE_MILLIS
    private val fetched = mutableListOf<String>()
    private var responses = mutableMapOf<String, String>()
    private val published = mutableListOf<OpenRouterDiscoveryState>()

    private fun store(cacheDir: File = folder.root) = OpenRouterDiscoveryStore(
        cacheDir = cacheDir,
        scope = CoroutineScope(SupervisorJob() + main),
        io = io,
        fetch = { url ->
            fetched += url
            responses[url] ?: throw IOException("offline")
        },
        clock = { now },
        publish = { published += it },
    )

    private fun drain() {
        repeat(5) {
            main.drain()
            io.drain()
        }
    }

    private fun writeTranscriptionCache(age: Long): List<OpenRouterAudioModel> {
        val models = OpenRouterDiscovery.parseTranscription(transcriptionBody).take(1)
        File(folder.root, "openrouter-transcription-models.json")
            .writeText(OpenRouterDiscovery.encodeTranscriptionCache(models, now - age))
        return models
    }

    @Test
    fun testStore_aFailureKeepsTheCachedModelsAndSaysSo() {
        val cached = writeTranscriptionCache(age = OpenRouterDiscovery.CACHE_LIFETIME_MILLIS + 1)
        val store = store()
        store.refreshTranscription()
        drain()
        assertEquals(listOf(OpenRouterDiscovery.TRANSCRIPTION_MODELS_URL), fetched)
        assertEquals(cached, store.current.transcriptionModels)
        assertTrue(store.current.transcriptionLoaded)
        assertTrue(store.current.transcriptionFailed)
        assertFalse(store.current.transcriptionLoading)
        assertEquals(store.current, published.last())
    }

    @Test
    fun testStore_withoutACacheAFailureLeavesOnlyTheBundledModels() {
        val store = store()
        store.refreshTranscription()
        drain()
        assertTrue(store.current.transcriptionModels.isEmpty())
        assertFalse(store.current.transcriptionLoaded)
        assertTrue(store.current.transcriptionFailed)
        val items = OpenRouterBrowser.transcriptionItems(store.current.transcriptionModels)
        assertEquals(OpenRouterBrowser.transcriptionItems, items)
    }

    @Test
    fun testStore_aFreshCacheSkipsTheNetworkUntilRefreshedByHand() {
        val cached = writeTranscriptionCache(age = 1)
        val store = store()
        store.refreshTranscription()
        drain()
        assertTrue(fetched.isEmpty())
        assertEquals(cached, store.current.transcriptionModels)

        responses[OpenRouterDiscovery.TRANSCRIPTION_MODELS_URL] = transcriptionBody
        store.refreshTranscription(force = true)
        drain()
        assertEquals(1, fetched.size)
        assertEquals(3, store.current.transcriptionModels.size)
        assertFalse(store.current.transcriptionFailed)
        val saved = File(folder.root, "openrouter-transcription-models.json").readText()
        assertEquals(3, OpenRouterDiscovery.decodeTranscriptionCache(saved, now)?.models?.size)
    }

    @Test
    fun testStore_requestsAreAtLeastAMinuteApart() {
        val store = store()
        store.refreshTranscription(force = true)
        drain()
        store.refreshTranscription(force = true)
        drain()
        assertEquals(1, fetched.size)
        now += OpenRouterDiscovery.RETRY_FLOOR_MILLIS
        store.refreshTranscription(force = true)
        drain()
        assertEquals(2, fetched.size)
    }

    @Test
    fun testStore_cleanupDiscoveryIsOptIn() {
        val body = JSONObject(RepoSources.fixture("openrouter-browser/cleanup-discovery.json"))
            .getJSONObject("response").toString()
        responses[OpenRouterDiscovery.CLEANUP_MODELS_URL] = body
        val store = store()
        store.refreshCleanup(force = true)
        drain()
        assertTrue(fetched.isEmpty())

        store.setCleanupEnabled(true)
        drain()
        assertEquals(listOf(OpenRouterDiscovery.CLEANUP_MODELS_URL), fetched)
        assertEquals(OpenRouterDiscovery.parseCleanup(body), store.current.cleanupModels)
        assertNotNull(File(folder.root, "openrouter-cleanup-models.json").takeIf { it.isFile })

        store.setCleanupEnabled(false)
        drain()
        assertFalse(store.current.cleanupLoading)
        assertEquals(1, fetched.size)
    }

    @Test
    fun testStore_restoreNamesASavedDiscoveredModelWithoutTheNetwork() {
        writeTranscriptionCache(age = 1)
        val store = store()
        store.restore()
        drain()
        assertTrue(fetched.isEmpty())
        val model = CloudCatalog.transcriptionModel("openrouter/transcription/openai/whisper-large-v3")
        assertEquals("Whisper Large v3", model.displayName)
        assertEquals(CloudProvider.OpenRouter, model.provider)
        assertEquals("openai/whisper-large-v3", model.apiName)
    }

    // endregion
}
