package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudCatalog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationEngineSelectorTest {
    private val engine = FakeEngine()
    private val prefs = MemoryPrefs(chosenMode = null)
    private val published = mutableListOf<EngineSelection>()
    private var active = false

    private fun selector(
        engine: SpeechEngine = this.engine,
        scope: CoroutineScope = CoroutineScope(Dispatchers.Unconfined),
        timings: DictationTimings = DictationTimings(),
    ) = DictationEngineSelector(
        engine,
        MemorySecrets("openai.apiKey" to "sk-test"),
        prefs,
        scope,
        timings,
        sessionActive = { active },
        currentLanguageTag = { "en-GB" },
        publish = { published += it },
    )

    /** Resolves every on-device check to [support] for [tag], counting the checks. */
    private class ResolvingEngine(
        private val tag: String,
        private val support: () -> LanguageSupport,
    ) : SpeechEngine by FakeEngine() {
        var checks = 0

        override fun capabilities() =
            RecognizerCapabilities(sdkInt = 36, speechServiceAvailable = true, onDeviceAvailable = true)

        override fun checkOnDeviceLanguage(languageTag: String, onResult: (LanguageResolution) -> Unit) {
            checks++
            onResult(LanguageResolution(support(), tag))
        }
    }

    private fun EngineSelection.status(mode: RecognitionMode) = options.single { it.mode == mode }.status

    @Test
    fun testRefresh_publishesTheCheckThenEachModesAvailabilityForTheSavedKeys() {
        engine.answerChecks = false
        val selector = selector()

        selector.refresh()
        assertTrue(selector.selection.checking)
        assertTrue(CloudCatalog.defaultTranscriptionModel.provider in selector.selection.savedKeys)
        assertTrue(selector.selection.options.isEmpty())

        engine.answerCheck()
        val settled = selector.selection
        assertFalse(settled.checking)
        assertEquals(ModeStatus.Ready, settled.status(RecognitionMode.Cloud))
        assertEquals(ModeStatus.Ready, settled.status(RecognitionMode.SpeechService))
        assertEquals(listOf(true, false), published.map { it.checking })
    }

    @Test
    fun testCloudModelWithoutAKey_needsOne_andIsPersisted() {
        val selector = selector()
        selector.refresh()
        val other = CloudCatalog.transcriptionModels.first { it.provider !in selector.selection.savedKeys }

        selector.chooseCloudModel(other)

        assertEquals(other.catalogId, prefs.cloudModelId)
        assertEquals(other, selector.selection.cloudModel)
        assertEquals(ModeStatus.NeedsKey, selector.selection.status(RecognitionMode.Cloud))
    }

    @Test
    fun testWhileASessionRuns_neitherRefreshNorAModeChoiceChangesTheSelection() {
        val selector = selector()
        active = true

        selector.refresh()
        selector.chooseMode(RecognitionMode.Cloud)

        assertTrue(published.isEmpty())
        assertNull(prefs.chosenMode)
        assertNull(selector.selection.chosenMode)
    }

    @Test
    fun testPlan_routesCloudToItsModel_andOnDeviceToTheLanguageTheRecogniserHas() {
        val selector = selector(engine = ResolvingEngine("en-US") { LanguageSupport.Installed })
        selector.refresh()
        selector.chooseMode(RecognitionMode.OnDevice)

        assertEquals(RecognitionMode.OnDevice, prefs.chosenMode)
        assertEquals(SessionPlan.Recognizer(RecognitionMode.OnDevice, "en-US"), selector.plan(RecognitionMode.OnDevice))
        assertEquals(
            SessionPlan.Recognizer(RecognitionMode.SpeechService, "en-GB"),
            selector.plan(RecognitionMode.SpeechService),
        )
        assertEquals(
            SessionPlan.Cloud(CloudCatalog.defaultTranscriptionModel, "en-GB"),
            selector.plan(RecognitionMode.Cloud),
        )
    }

    @Test
    fun testDownloadWatch_rechecksUntilTheModelIsInstalled() {
        val answers = ArrayDeque(listOf(LanguageSupport.Downloadable, LanguageSupport.Downloading))
        val resolving = ResolvingEngine("en-GB") { answers.removeFirstOrNull() ?: LanguageSupport.Installed }
        lateinit var watched: DictationEngineSelector
        // runBlocking returns once the watch has ended.
        runBlocking {
            watched = selector(
                engine = resolving,
                scope = this,
                timings = DictationTimings(downloadCheckIntervalMs = 1, downloadChecks = 10),
            )
            watched.refresh()
            watched.downloadOnDeviceModel()
        }

        assertEquals("the first check plus a recheck per state until Installed", 3, resolving.checks)
        assertEquals(ModeStatus.Ready, watched.selection.status(RecognitionMode.OnDevice))
    }
}
