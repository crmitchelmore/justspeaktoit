package com.justspeaktoit.android.ime

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.live.LiveOutcome
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.dictation.CloudCapture
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.DictationState
import com.justspeaktoit.android.dictation.DictationTimings
import com.justspeaktoit.android.dictation.DownloadedTranscription
import com.justspeaktoit.android.dictation.FakeCloud
import com.justspeaktoit.android.dictation.FakeEngine
import com.justspeaktoit.android.dictation.FakeInterruptions
import com.justspeaktoit.android.dictation.FakeLiveClient
import com.justspeaktoit.android.dictation.FakeLiveSessions
import com.justspeaktoit.android.dictation.FakeLocalTranscriber
import com.justspeaktoit.android.dictation.FakeRecorders
import com.justspeaktoit.android.dictation.InterruptionSignal
import com.justspeaktoit.android.dictation.MemorySecrets
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.dictation.RecorderRetirement
import com.justspeaktoit.android.dictation.SessionRequests
import com.justspeaktoit.android.dictation.SilenceSettings
import com.justspeaktoit.android.dictation.ViewModelHarness
import com.justspeaktoit.android.local.LocalTranscriber
import com.justspeaktoit.android.resources.SystemResourceKind
import com.justspeaktoit.android.resources.SystemResourceRegistry
import kotlinx.coroutines.CompletableDeferred
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
import java.io.File
import java.util.concurrent.Executors

/** The keyboard's live Cloud path (#1668), on the app's real session controller with a fake provider. */
class KeyboardLiveDictationTest {
    @get:Rule val folder = TemporaryFolder()

    private val engine = FakeEngine()
    private val recorders = FakeRecorders()
    private val cloud = FakeCloud()
    private val live = FakeLiveSessions()
    private val interruptions = FakeInterruptions()
    private val resources = SystemResourceRegistry()
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "test-main") }
    private val main = executor.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + main)
    private val states = MutableStateFlow<DictationState>(DictationState.Idle)
    private val seen = mutableListOf<DictationState>()
    private var rules = emptyList<CorrectionRule>()
    private var finishTimeoutMs = KeyboardPolicy.FINISH_TIMEOUT_MS
    private val localTranscriber = FakeLocalTranscriber()
    private val downloadedModels = mutableMapOf<String, File>()
    private var transcriber: LocalTranscriber = localTranscriber

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
            interruptions = interruptions,
            finishTimeoutMs = finishTimeoutMs,
            downloaded = DownloadedTranscription({ downloadedModels[it] }, transcriber),
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
    fun testDownloadedModel_transcribesOnThePhoneWithCorrections() {
        rules = listOf(CorrectionRule("Kubernetes", listOf("local words")))
        val model = folder.newFile("ggml-tiny.bin")
        downloadedModels[TINY] = model
        onMain { keyboard.startLocal(TINY, "en-GB") }
        await { it is DictationState.Listening }

        onMain { keyboard.stop() }

        assertEquals(DictationState.Done(RecognitionMode.Downloaded, "Kubernetes"), await { !it.isActive })
        val call = localTranscriber.calls.single()
        assertEquals(model, call.model)
        assertEquals("en-GB", call.languageTag)
        assertTrue("a downloaded model never falls back to the cloud", cloud.transcriptions.isEmpty())
        assertTrue(live.created.isEmpty())
        assertEquals(0, engine.started.size)
    }

    @Test
    fun testDownloadedModelThatOutlastsTheKeyboardBound_failsVisiblyAsDownloaded() {
        finishTimeoutMs = 200L
        downloadedModels[TINY] = folder.newFile("ggml-tiny.bin")
        val release = CompletableDeferred<Unit>()
        transcriber = object : LocalTranscriber {
            override val available = true

            override suspend fun transcribe(model: File, audio: File, languageTag: String?): String {
                release.await()
                return "too late"
            }
        }
        onMain { keyboard.startLocal(TINY, "en-GB") }
        await { it is DictationState.Listening }

        onMain { keyboard.stop() }

        val failed = await { it is DictationState.Failed }
        assertEquals(DictationState.Failed(RecognitionMode.Downloaded, DictationFailure.NetworkTimeout, ""), failed)
        assertFalse(onMain { keyboard.isRunning })
        assertEquals("no other recogniser is started instead", 0, engine.started.size)
        assertTrue(cloud.transcriptions.isEmpty())
        release.complete(Unit)
        onMain { }
        assertTrue("a late transcript is ignored", seen.none { it is DictationState.Done })
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

    @Test
    fun testInterruptions_pauseOnTransientFocusLossAndStopVisiblyOnHeadsetChange() {
        val client = start(CloudProvider.OpenAI)
        ViewModelHarness.await(client.connected)
        await { it is DictationState.Listening }
        assertEquals("a capturing Cloud session holds audio focus", listOf(true), interruptions.starts.toList())

        onMain { interruptions.signal(InterruptionSignal.FocusLostTransient) }
        assertTrue(onMain { keyboard.isPaused })
        onMain { interruptions.signal(InterruptionSignal.FocusGained) }
        assertFalse(onMain { keyboard.isPaused })

        onMain { interruptions.signal(InterruptionSignal.InputDeviceChanged) }
        val failed = await { it is DictationState.Failed } as DictationState.Failed
        assertEquals(DictationFailure.AudioDeviceChanged, failed.failure)
        assertTrue(client.cancelled)
        assertFalse(onMain { keyboard.isRunning })
        assertFalse("watching ends with capture", interruptions.watching)
        assertTrue(cloud.transcriptions.isEmpty())
    }

    @Test
    fun testFinishedSession_stopsWatchingInterruptions() {
        val client = start(CloudProvider.OpenAI)
        ViewModelHarness.await(client.connected)
        await { it is DictationState.Listening }
        assertTrue(interruptions.watching)

        onMain { keyboard.stop() }
        assertFalse("focus is abandoned once capture ends", interruptions.watching)
        ViewModelHarness.await(client.finished)
        client.listener.onEnd(LiveOutcome.Completed("done"))
        await { it is DictationState.Done }
        assertEquals(1, interruptions.starts.size)
    }

    @Test(expected = IllegalArgumentException::class)
    fun testBatchModel_isNeverStarted() {
        val batch = CloudCatalog.transcriptionModels.first { it.live == null }
        onMain { keyboard.start(batch, "en-GB") }
    }

    private companion object {
        const val TINY = "local/whisperkit/tiny"
    }
}
