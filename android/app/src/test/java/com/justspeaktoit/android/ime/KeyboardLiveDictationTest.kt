package com.justspeaktoit.android.ime

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.live.LiveOutcome
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.dictation.CloudCapture
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.DictationState
import com.justspeaktoit.android.dictation.DictationTimings
import com.justspeaktoit.android.dictation.FakeCloud
import com.justspeaktoit.android.dictation.FakeEngine
import com.justspeaktoit.android.dictation.FakeLiveClient
import com.justspeaktoit.android.dictation.FakeLiveSessions
import com.justspeaktoit.android.dictation.FakeRecorders
import com.justspeaktoit.android.dictation.MemorySecrets
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.dictation.RecorderRetirement
import com.justspeaktoit.android.dictation.SessionRequests
import com.justspeaktoit.android.dictation.SilenceSettings
import com.justspeaktoit.android.dictation.ViewModelHarness
import com.justspeaktoit.android.resources.SystemResourceKind
import com.justspeaktoit.android.resources.SystemResourceRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
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
import java.util.concurrent.Executors

/** The keyboard's live Cloud path (#1668), on the app's real session controller with a fake provider. */
class KeyboardLiveDictationTest {
    @get:Rule val folder = TemporaryFolder()

    private val engine = FakeEngine()
    private val recorders = FakeRecorders()
    private val cloud = FakeCloud()
    private val live = FakeLiveSessions()
    private val resources = SystemResourceRegistry()
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "test-main") }
    private val main = executor.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + main)
    private val states = MutableStateFlow<DictationState>(DictationState.Idle)
    private val seen = mutableListOf<DictationState>()
    private var rules = emptyList<CorrectionRule>()
    private var finishTimeoutMs = KeyboardPolicy.FINISH_TIMEOUT_MS

    private val keyboard by lazy {
        val cacheDir = folder.newFolder("keyboard-live")
        val capture = CloudCapture(recorders, cacheDir, Dispatchers.IO, RecorderRetirement(Dispatchers.IO), resources)
        val secrets = MemorySecrets(CloudProvider.OpenAI.credentialId to "sk-test")
        KeyboardLiveDictation(
            engine = engine,
            capture = capture,
            requests = SessionRequests(cloud, secrets, capture, Dispatchers.IO, DictationTimings()) { _, _ -> },
            resources = resources,
            scope = scope,
            cacheDir = cacheDir,
            corrections = { rules },
            silence = { SilenceSettings() },
            onState = {
                seen += it
                states.value = it
            },
            liveSessions = live,
            finishTimeoutMs = finishTimeoutMs,
        )
    }

    @After
    fun tearDown() {
        scope.cancel()
        main.close()
    }

    private fun <T> onMain(block: () -> T): T = runBlocking { withContext(main) { block() } }

    private fun await(predicate: (DictationState) -> Boolean): DictationState =
        runBlocking { withTimeout(ViewModelHarness.TIMEOUT_MS) { states.first(predicate) } }

    private fun eventually(message: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + ViewModelHarness.TIMEOUT_MS
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { message }
            Thread.sleep(10)
        }
    }

    private fun start(provider: CloudProvider): FakeLiveClient {
        val model = CloudCatalog.liveTranscriptionModels.first { it.provider == provider }
        onMain { keyboard.start(model, "en-GB") }
        return live.last
    }

    @Test
    fun testLiveSession_showsPartialsAndFinishesWithCorrectedTextAndNoUpload() {
        rules = listOf(CorrectionRule("Kubernetes", listOf("cooper netties")))
        val client = start(CloudProvider.OpenAI)
        ViewModelHarness.await(client.connected)
        assertEquals("the key is read in process", "sk-test", client.key)
        val microphone = resources.holds.value.single { it.kind == SystemResourceKind.Microphone }
        assertEquals("DictationKeyboardService", microphone.owner)

        client.listener.onPartial("hello cooper")
        await { (it as? DictationState.Listening)?.partial == "hello cooper" }

        onMain { keyboard.stop() }
        ViewModelHarness.await(client.finished)
        client.listener.onEnd(LiveOutcome.Completed("hello cooper netties"))

        assertEquals(DictationState.Done(RecognitionMode.Cloud, "hello Kubernetes"), await { !it.isActive })
        assertFalse(onMain { keyboard.isRunning })
        assertTrue("a live session never falls back to an upload", cloud.transcriptions.isEmpty())
        eventually("the local copy of the audio is deleted") { !recorders.last.file.exists() }
        eventually("the microphone is released") {
            resources.holds.value.none { it.kind == SystemResourceKind.Microphone }
        }
    }

    @Test
    fun testFinishThatOutlastsTheKeyboardBound_failsVisiblyWithWhatWasHeard() {
        finishTimeoutMs = 200L
        val client = start(CloudProvider.OpenAI)
        ViewModelHarness.await(client.connected)
        client.listener.onPartial("half a")
        await { (it as? DictationState.Listening)?.partial == "half a" }

        onMain { keyboard.stop() }
        ViewModelHarness.await(client.finished)

        val failed = await { it is DictationState.Failed }
        assertEquals(DictationState.Failed(RecognitionMode.Cloud, DictationFailure.NetworkTimeout, "half a"), failed)
        assertTrue(client.cancelled)
        assertEquals("no other recogniser is started instead", 0, engine.started.size)
        assertTrue(cloud.transcriptions.isEmpty())

        // A late result from the abandoned stream is ignored.
        client.listener.onEnd(LiveOutcome.Completed("half a sentence"))
        onMain { }
        assertTrue(seen.none { it is DictationState.Done })
    }

    @Test
    fun testMissingKey_failsVisiblyWithoutConnecting() {
        val client = start(CloudProvider.Deepgram)

        val failed = await { it is DictationState.Failed }
        assertEquals(DictationState.Failed(RecognitionMode.Cloud, DictationFailure.MissingKey, ""), failed)
        assertNull(client.key)
        assertEquals(0, engine.started.size)
    }

    @Test
    fun testCancel_endsTheStreamAndReportsNothingFurther() {
        val client = start(CloudProvider.OpenAI)
        ViewModelHarness.await(client.connected)

        onMain { keyboard.cancel() }
        val reported = onMain { seen.size }
        client.listener.onPartial("too late")
        onMain { }

        assertTrue(client.cancelled)
        assertFalse(onMain { keyboard.isRunning })
        assertEquals(reported, onMain { seen.size })
    }

    @Test(expected = IllegalArgumentException::class)
    fun testBatchModel_isNeverStarted() {
        val batch = CloudCatalog.transcriptionModels.first { it.live == null }
        onMain { keyboard.start(batch, "en-GB") }
    }
}
