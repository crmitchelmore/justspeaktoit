package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.RequestReleasedException
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.HistoryStore
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.resources.SystemResourceHold
import com.justspeaktoit.android.resources.SystemResourceKind
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.settings.RecordingCue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

/** Drives the session lifecycle directly, without a ViewModel, on a single test main thread. */
class DictationSessionControllerTest {
    @get:Rule val folder = TemporaryFolder()

    private val engine = FakeEngine()
    private val recorders = FakeRecorders()
    private val cloud = FakeCloud()
    private val resources = SystemResourceRegistry()
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "test-main") }
    private val main = executor.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + main)
    private val states = MutableStateFlow(SessionState())
    private val history = MutableStateFlow<List<HistoryEntry>>(emptyList())
    private var keepAudio = false
    private var rules = emptyList<CorrectionRule>()
    private var cleanup: CleanupModel? = null

    /** Each cue played, with how many times the Cloud recorder had been stopped when it played. */
    private val cues = CopyOnWriteArrayList<Pair<RecordingCue, Int>>()

    private val controller by lazy {
        val cacheDir = folder.newFolder("cache")
        val capture = CloudCapture(recorders, cacheDir, Dispatchers.IO, RecorderRetirement(Dispatchers.IO), resources)
        val secrets = MemorySecrets(
            "openai.apiKey" to "sk-test",
            CloudCatalog.cleanupModels.first().provider.credentialId to "sk-cleanup",
        )
        DictationSessionController(
            engine = engine,
            capture = capture,
            requests = SessionRequests(cloud, secrets, capture, Dispatchers.IO, DictationTimings()) { _, _ -> },
            history = DictationHistory(
                HistoryStore(MemoryHistoryFile(), deleteAudio = { File(it).delete() }),
                File(folder.root, "recordings"),
                scope,
                Dispatchers.IO,
            ) { entries, _ -> history.value = entries },
            resources = resources,
            scope = scope,
            cacheDir = cacheDir,
            settings = object : SessionSettings {
                override val retention = Retention.Month
                override val keepAudioOnCancel get() = keepAudio
                override val cleanupModel get() = cleanup
                override val corrections get() = rules
            },
            cues = { cue ->
                cues += cue to (recorders.created.lastOrNull()?.stops ?: 0)
                CUE_MS
            },
            publish = { states.value = it },
        )
    }

    @After
    fun tearDown() {
        scope.cancel()
        main.close()
    }

    private fun <T> onMain(block: () -> T): T = runBlocking { withContext(main) { block() } }

    private fun <T> await(flow: StateFlow<T>, predicate: (T) -> Boolean): T =
        runBlocking { withTimeout(ViewModelHarness.TIMEOUT_MS) { flow.first(predicate) } }

    private fun holds(kind: SystemResourceKind): List<SystemResourceHold> =
        resources.holds.value.filter { it.kind == kind }

    private fun startCloud(): FakeRecorder {
        onMain { controller.start(SessionPlan.Cloud(CloudCatalog.defaultTranscriptionModel, "en-GB")) }
        await(states) { it.dictation is DictationState.Listening }
        return recorders.last
    }

    @Test
    fun testRecognizerPlan_startsTheEngineInItsLanguage_andHoldsTheMicrophoneUntilTheResult() {
        onMain { controller.start(SessionPlan.Recognizer(RecognitionMode.SpeechService, "fr-FR")) }

        assertEquals(listOf(RecognitionMode.SpeechService), engine.started.toList())
        assertEquals(listOf("fr-FR"), engine.startedLanguages.toList())
        val microphone = holds(SystemResourceKind.Microphone).single()
        assertEquals("Listening through the speech recognition service", microphone.reason)

        onMain { checkNotNull(engine.onEvent)(DictationEvent.Final("bonjour")) }

        assertEquals(DictationState.Done(RecognitionMode.SpeechService, "bonjour"), states.value.dictation)
        assertTrue(holds(SystemResourceKind.Microphone).isEmpty())
        val entry = await(history) { it.isNotEmpty() }.single()
        assertEquals("bonjour", entry.text)
        assertNull("a recogniser session records no cloud model", entry.model)
    }

    @Test
    fun testCloudSession_playsStartOverSilencedAudio_andStopOnlyAfterTheMicrophoneStops() {
        val rec = startCloud()
        assertEquals(listOf(RecordingCue.Start to 0), cues.toList())
        assertEquals(CUE_MS, rec.mutedFor)

        onMain { controller.stop() }
        await(states) { it.dictation is DictationState.Done }

        assertEquals(listOf(RecordingCue.Start to 0, RecordingCue.Stop to 1), cues.toList())
    }

    @Test
    fun testCancelledCloudSession_playsNoStopCue() {
        startCloud()

        onMain { controller.cancel() }
        await(states) { it.dictation == DictationState.Idle && !it.releasingMicrophone }

        assertEquals(listOf(RecordingCue.Start), cues.map { it.first })
    }

    @Test
    fun testRecognizerSession_playsStartWhenListening_andStopWhenItEnds_butNotOnFailure() {
        onMain { controller.start(SessionPlan.Recognizer(RecognitionMode.SpeechService, "en-GB")) }
        assertTrue("no cue before the recogniser is ready", cues.isEmpty())
        onMain { checkNotNull(engine.onEvent)(DictationEvent.Ready) }
        onMain { controller.stop() }
        onMain { checkNotNull(engine.onEvent)(DictationEvent.Final("done")) }
        assertEquals(
            "the final after a stop plays no second Stop",
            listOf(RecordingCue.Start, RecordingCue.Stop),
            cues.map { it.first },
        )

        cues.clear()
        onMain { controller.start(SessionPlan.Recognizer(RecognitionMode.SpeechService, "en-GB")) }
        onMain { checkNotNull(engine.onEvent)(DictationEvent.Partial("hello")) }
        onMain { checkNotNull(engine.onEvent)(DictationEvent.Final("hello")) }
        assertEquals("a recogniser that ends after a pause plays Stop", RecordingCue.Stop, cues.last().first)

        cues.clear()
        onMain { controller.start(SessionPlan.Recognizer(RecognitionMode.SpeechService, "en-GB")) }
        onMain { checkNotNull(engine.onEvent)(DictationEvent.Ready) }
        onMain { checkNotNull(engine.onEvent)(DictationEvent.Error(DictationFailure.Network)) }
        assertEquals(listOf(RecordingCue.Start), cues.map { it.first })
    }

    @Test
    fun testCancelWhileTheRecorderStopStalls_holdsTheMicrophoneUntilItReallyStops() {
        val gate = CountDownLatch(1)
        recorders.stopGate = gate
        val rec = startCloud()

        onMain { controller.cancel() }
        ViewModelHarness.await(rec.stopEntered)
        assertEquals(SessionState(DictationState.Idle, releasingMicrophone = true), states.value)
        assertEquals(1, holds(SystemResourceKind.Microphone).size)

        gate.countDown()
        await(states) { !it.releasingMicrophone }
        assertTrue(holds(SystemResourceKind.Microphone).isEmpty())
        assertFalse(rec.file.exists())
        assertEquals(1, rec.stops)
    }

    @Test
    fun testReleasingTheMicrophoneFromSettings_cancelsTheCaptureAndKeepsItsAudio() {
        keepAudio = true
        val rec = startCloud()
        val hold = holds(SystemResourceKind.Microphone).single()

        onMain { resources.release(hold.id) }

        val kept = await(history) { it.isNotEmpty() }.single()
        assertEquals(HistoryStatus.Cancelled, kept.status)
        assertTrue(File(checkNotNull(kept.audioPath)).exists())
        assertEquals(DictationState.Idle, states.value.dictation)
        assertEquals(1, rec.stops)
        assertTrue(holds(SystemResourceKind.Microphone).isEmpty())
    }

    @Test
    fun testReleasingTheUploadFromSettings_isACancelThatKeepsTheRecording() {
        keepAudio = true
        val entered = CountDownLatch(1)
        cloud.onTranscribe = { call ->
            entered.countDown()
            while (!call.released) Thread.sleep(5)
            throw RequestReleasedException()
        }
        startCloud()
        onMain { controller.stop() }
        ViewModelHarness.await(entered)
        assertTrue("the microphone is free during the upload", holds(SystemResourceKind.Microphone).isEmpty())

        resources.release(holds(SystemResourceKind.ProviderConnection).single().id)

        await(states) { it.dictation == DictationState.Idle }
        val kept = await(history) { it.isNotEmpty() }.single()
        assertEquals(HistoryStatus.Cancelled, kept.status)
        assertEquals(CloudCatalog.defaultTranscriptionModel.catalogId, kept.model)
        assertTrue(File(checkNotNull(kept.audioPath)).exists())
        assertTrue(holds(SystemResourceKind.ProviderConnection).isEmpty())
    }

    @Test
    fun testPersonalCorrections_fixEveryFinalAndBiasTheCloudModel() {
        rules = listOf(CorrectionRule("Kubernetes", listOf("cooper netties")))
        onMain { controller.start(SessionPlan.Recognizer(RecognitionMode.SpeechService, "en-GB")) }
        onMain { checkNotNull(engine.onEvent)(DictationEvent.Final("ship Cooper Netties")) }
        assertEquals(DictationState.Done(RecognitionMode.SpeechService, "ship Kubernetes"), states.value.dictation)
        await(history) { it.isNotEmpty() }

        cloud.onTranscribe = { "cooper netties works" }
        startCloud()
        onMain { controller.stop() }
        await(states) { it.dictation.text() == "Kubernetes works" }
        assertEquals(listOf("Kubernetes"), cloud.transcriptions.single().vocabulary)
    }

    @Test
    fun testCleanupThatRestoresAMisheardWord_isCorrectedAgain() {
        rules = listOf(CorrectionRule("Kubernetes", listOf("cooper netties")))
        cleanup = CloudCatalog.cleanupModels.first()
        cloud.onCleanup = { "Ship Cooper Netties." }
        onMain { controller.start(SessionPlan.Recognizer(RecognitionMode.SpeechService, "en-GB")) }
        onMain { checkNotNull(engine.onEvent)(DictationEvent.Final("ship cooper netties")) }
        await(states) { it.cleanup == CleanupStatus.Applied }
        assertEquals("ship Kubernetes", cloud.cleanups.single())
        assertEquals("Ship Kubernetes.", states.value.dictation.text())
    }

    private fun DictationState.text() = (this as? DictationState.Done)?.transcript

    private companion object {
        const val CUE_MS = 150L
    }
}
