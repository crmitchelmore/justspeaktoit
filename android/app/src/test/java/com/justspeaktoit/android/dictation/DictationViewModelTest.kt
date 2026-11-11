package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.history.HistoryStatus
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.Locale
import java.util.concurrent.CountDownLatch

/** Drives the real ViewModel through its public API with fake engine, recorder, cloud and stores. */
class DictationViewModelTest {
    @get:Rule val folder = TemporaryFolder()

    private lateinit var h: ViewModelHarness

    @Before
    fun setUp() {
        h = ViewModelHarness(folder.root)
    }

    @After
    fun tearDown() {
        h.close()
    }

    private fun startCloud(): FakeRecorder {
        val vm = h.ready()
        h.onMain { vm.start() }
        h.awaitState { it.dictation is DictationState.Listening }
        return h.recorders.last
    }

    private fun awaitGone(file: File) {
        val end = System.currentTimeMillis() + ViewModelHarness.TIMEOUT_MS
        while (file.exists() && System.currentTimeMillis() < end) Thread.sleep(5)
        assertFalse("$file still exists", file.exists())
    }

    @Test
    fun testCloudStartStop_transcribesRecordsHistoryAndDeletesRecording() {
        val rec = startCloud()
        assertTrue(rec.startedCapture)

        h.onMain { h.viewModel.stop() }
        val done = h.awaitState { it.dictation is DictationState.Done && it.history.isNotEmpty() }

        assertEquals(DictationState.Done(RecognitionMode.Cloud, "hello world"), done.dictation)
        assertEquals(1, rec.stops)
        assertFalse("the upload file is temporary", rec.file.exists())
        val entry = done.history.single()
        assertEquals(HistoryStatus.Completed, entry.status)
        assertEquals("hello world", entry.text)
        assertEquals("openai/gpt-transcribe", entry.model)
        assertEquals(RecognitionMode.Cloud.name, entry.mode)
        val request = h.cloud.transcriptions.single()
        assertEquals("openai/gpt-transcribe", request.model)
        assertEquals(Locale.getDefault().toLanguageTag(), request.languageTag)

        h.onMain { h.viewModel.clearResult() }
        assertEquals(DictationState.Idle, h.viewModel.state.value.dictation)
        assertEquals(1, h.viewModel.state.value.history.size)
    }

    @Test
    fun testShortRecording_failsAsNoSpeechWithoutUploading() {
        h.recorders.bytes = 100
        startCloud()
        h.onMain { h.viewModel.stop() }
        val failed = h.awaitState { it.dictation is DictationState.Failed && it.history.isNotEmpty() }

        assertEquals(DictationFailure.NoSpeech, (failed.dictation as DictationState.Failed).failure)
        assertTrue(h.cloud.transcriptions.isEmpty())
        assertEquals(DictationFailure.NoSpeech.name, failed.history.single().failure)
    }

    @Test
    fun testKeyRemovedBeforeUpload_failsAsInvalidKey() {
        startCloud()
        h.secrets.remove("openai.apiKey")
        h.onMain { h.viewModel.stop() }
        val failed = h.awaitState { it.dictation is DictationState.Failed }

        assertEquals(DictationFailure.InvalidKey, (failed.dictation as DictationState.Failed).failure)
        assertTrue(h.cloud.transcriptions.isEmpty())
    }

    @Test
    fun testMicrophoneThatCannotOpen_failsAsAudioAndLeavesNoFile() {
        h.recorders.opens = false
        val vm = h.ready()
        h.onMain { vm.start() }
        val failed = h.awaitState { it.dictation is DictationState.Failed }

        assertEquals(DictationFailure.Audio, (failed.dictation as DictationState.Failed).failure)
        assertTrue(h.cacheDir.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun testCancelWithoutKeepingAudio_releasesMicrophoneAndRecordsNothing() {
        h.prefs.keepAudioOnCancel = false
        val rec = startCloud()
        h.onMain { h.viewModel.cancel() }
        h.awaitState { it.dictation == DictationState.Idle && !it.releasingMicrophone }

        assertEquals(1, rec.stops)
        assertFalse(rec.file.exists())
        h.onMain { }
        assertTrue(h.viewModel.state.value.history.isEmpty())
        assertTrue(h.cloud.transcriptions.isEmpty())
    }

    @Test
    fun testKeptRecording_retryFailureKeepsAudio_thenSuccessReplacesEntryInPlace() {
        val rec = startCloud()
        h.onMain { h.viewModel.cancel() }
        val kept = h.awaitState { it.history.isNotEmpty() && !it.releasingMicrophone }.history.single()
        assertEquals(HistoryStatus.Cancelled, kept.status)
        val audio = File(checkNotNull(kept.audioPath))
        assertEquals(h.recordingsDir.absoluteFile, audio.parentFile?.absoluteFile)
        assertTrue(audio.exists())
        assertFalse("the recording moved into History", rec.file.exists())

        h.cloud.onTranscribe = { throw CloudException(DictationFailure.Server, "boom") }
        h.onMain { h.viewModel.transcribeHistoryEntry(kept.id) }
        val failed = h.awaitState { it.transcribingEntryId == null && it.history.single().failure != null }
        assertEquals(DictationFailure.Server.name, failed.history.single().failure)
        assertEquals(HistoryStatus.Cancelled, failed.history.single().status)
        assertTrue("a failed retry keeps the audio", audio.exists())

        val gate = CountDownLatch(1)
        h.cloud.onTranscribe = {
            gate.await()
            "kept words"
        }
        h.onMain { h.viewModel.transcribeHistoryEntry(kept.id) }
        h.awaitState { it.transcribingEntryId == kept.id }
        // A second request while one runs is ignored.
        h.onMain { h.viewModel.transcribeHistoryEntry(kept.id) }
        gate.countDown()
        // The busy marker clears only once History holds the updated entry.
        val done = h.awaitState { it.transcribingEntryId == null }
        val entry = done.history.single()
        assertEquals(kept.id, entry.id)
        assertEquals(HistoryStatus.Completed, entry.status)
        assertEquals("kept words", entry.text)
        assertEquals("openai/gpt-transcribe", entry.model)
        assertNull(entry.failure)
        assertNull(entry.audioPath)
        assertFalse("success deletes the kept audio", audio.exists())
        assertEquals(2, h.cloud.transcriptions.size)
    }

    @Test
    fun testCleanup_replacesItsOwnEntry_newestSessionFirst_andShowOriginalRestores() {
        h.prefs.cleanupEnabled = true
        h.secrets.write("openrouter.apiKey", "or-test")
        h.cloud.onCleanup = { text -> text.replaceFirstChar { it.uppercaseChar() } + "." }

        h.cloud.onTranscribe = { "first" }
        startCloud()
        h.onMain { h.viewModel.stop() }
        h.awaitState { it.cleanup == CleanupStatus.Applied && it.history.firstOrNull()?.cleanedUp == true }

        h.cloud.onTranscribe = { "second" }
        h.onMain { h.viewModel.start() }
        h.awaitState { it.dictation is DictationState.Listening }
        h.onMain { h.viewModel.stop() }
        val cleaned = h.awaitState { it.cleanup == CleanupStatus.Applied && it.history.size == 2 && it.history[0].cleanedUp }

        assertEquals(DictationState.Done(RecognitionMode.Cloud, "Second."), cleaned.dictation)
        assertEquals("second", cleaned.originalTranscript)
        assertEquals(listOf("Second.", "First."), cleaned.history.map { it.text })
        assertEquals(listOf("first", "second"), h.cloud.cleanups.toList())

        h.onMain { h.viewModel.showOriginal() }
        val original = h.awaitState { it.history[0].text == "second" }
        assertEquals(DictationState.Done(RecognitionMode.Cloud, "second"), original.dictation)
        assertFalse(original.history[0].cleanedUp)
        assertEquals("First.", original.history[1].text)
    }

    @Test
    fun testCleanupFailure_keepsTranscript() {
        h.prefs.cleanupEnabled = true
        h.secrets.write("openrouter.apiKey", "or-test")
        h.cloud.onCleanup = { throw CloudException(DictationFailure.Server, "boom") }
        startCloud()
        h.onMain { h.viewModel.stop() }
        val failed = h.awaitState { it.cleanup == CleanupStatus.Failed && it.history.isNotEmpty() }

        assertEquals(DictationState.Done(RecognitionMode.Cloud, "hello world"), failed.dictation)
        assertEquals("hello world", failed.history.single().text)
        assertFalse(failed.history.single().cleanedUp)
    }

    @Test
    fun testCancelDuringUpload_abortsRequestAndDropsItsResult() {
        val entered = CountDownLatch(1)
        val returned = CountDownLatch(1)
        h.cloud.onTranscribe = { call ->
            entered.countDown()
            while (!call.cancelled) Thread.sleep(5)
            returned.countDown()
            throw CloudException(DictationFailure.Network, "aborted")
        }
        startCloud()
        h.onMain { h.viewModel.stop() }
        ViewModelHarness.await(entered)
        h.onMain { h.viewModel.cancel() }
        ViewModelHarness.await(returned)
        Thread.sleep(50)
        h.onMain { }

        assertEquals(DictationState.Idle, h.viewModel.state.value.dictation)
        assertTrue(h.viewModel.state.value.history.isEmpty())
    }

    @Test
    fun testUploadPastItsDeadline_isAbortedAndFailsAsNetworkTimeout() {
        h.timings = DictationTimings(transcribeMs = 100)
        h.cloud.onTranscribe = { call ->
            while (!call.cancelled) Thread.sleep(5)
            throw CloudException(DictationFailure.Network, "Socket closed")
        }
        val rec = startCloud()
        h.onMain { h.viewModel.stop() }
        val failed = h.awaitState { it.dictation is DictationState.Failed && it.history.isNotEmpty() }

        assertEquals(DictationFailure.NetworkTimeout, (failed.dictation as DictationState.Failed).failure)
        assertTrue(h.cloud.transcriptions.single().call.cancelled)
        assertEquals(DictationFailure.NetworkTimeout.name, failed.history.single().failure)
        assertFalse("the upload file is deleted after a failure too", rec.file.exists())
    }

    @Test
    fun testLeavingTheApp_failsCaptureAndReleasesMicrophone() {
        val rec = startCloud()
        h.onMain { h.viewModel.onLeftApp() }
        val failed = h.awaitState { it.dictation is DictationState.Failed && !it.releasingMicrophone }

        assertEquals(DictationFailure.LeftApp, (failed.dictation as DictationState.Failed).failure)
        assertEquals(1, rec.stops)
        assertFalse(rec.file.exists())
        assertTrue(h.cloud.transcriptions.isEmpty())
    }

    @Test
    fun testCaptureFailure_failsAsAudio_andLateCallbacksFromIt_doNotTouchTheNextSession() {
        val first = startCloud()
        first.onCaptureFailed()
        val failed = h.awaitState { it.dictation is DictationState.Failed && !it.releasingMicrophone }
        assertEquals(DictationFailure.Audio, (failed.dictation as DictationState.Failed).failure)
        assertEquals(1, first.stops)

        h.onMain { h.viewModel.start() }
        h.awaitState { it.dictation is DictationState.Listening }
        val second = h.recorders.last
        first.onCaptureFailed()
        first.onLimitReached()
        h.onMain { }
        h.onMain { }

        assertTrue(h.viewModel.state.value.dictation is DictationState.Listening)
        assertEquals(0, second.stops)
    }

    @Test
    fun testRecordingLimit_stopsAndTranscribes() {
        startCloud().onLimitReached()
        val done = h.awaitState { it.dictation is DictationState.Done }
        assertEquals("hello world", (done.dictation as DictationState.Done).transcript)
    }

    @Test
    fun testSpeechServiceSession_runsThroughEngineAndRecordsNoModel() {
        h.prefs.chosenMode = RecognitionMode.SpeechService
        val vm = h.ready()
        h.onMain { vm.start() }
        assertEquals(listOf(RecognitionMode.SpeechService), h.engine.started.toList())
        h.onMain {
            val emit = checkNotNull(h.engine.onEvent)
            emit(DictationEvent.Ready)
            emit(DictationEvent.Partial("hi"))
        }
        h.onMain { vm.stop() }
        assertEquals(1, h.engine.stops)
        h.onMain { checkNotNull(h.engine.onEvent)(DictationEvent.Final("hi there")) }
        val done = h.awaitState { it.dictation is DictationState.Done && it.history.isNotEmpty() }

        assertEquals(DictationState.Done(RecognitionMode.SpeechService, "hi there"), done.dictation)
        assertNull(done.history.single().model)
        assertTrue(h.recorders.created.isEmpty())
    }

    @Test
    fun testAutoStart_waitsForAvailability() {
        h.engine.answerChecks = false
        h.onMain {
            h.viewModel.refreshAvailability()
            h.viewModel.requestAutoStart()
        }
        assertEquals(DictationState.Idle, h.viewModel.state.value.dictation)
        assertTrue(h.recorders.created.isEmpty())

        h.onMain { h.engine.answerCheck() }
        h.awaitState { it.dictation is DictationState.Listening }
        assertEquals(1, h.recorders.created.size)
    }

    @Test
    fun testClear_closesEngineAndReleasesTheRecordingOffTheMainThread() {
        val rec = startCloud()
        h.clear()

        assertTrue(h.engine.closed)
        ViewModelHarness.await(rec.stopped)
        awaitGone(rec.file)
        // Callbacks from the released recording reach nothing.
        rec.onLimitReached()
        rec.onCaptureFailed()
        Thread.sleep(50)
        assertEquals(1, h.recorders.created.size)
        assertTrue(h.cloud.transcriptions.isEmpty())
    }
}
