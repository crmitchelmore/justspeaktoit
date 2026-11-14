package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.AudioInput
import com.justspeaktoit.android.cloud.AudioInputChoice
import com.justspeaktoit.android.cloud.AudioInputKind
import com.justspeaktoit.android.cloud.CaptureLevel
import com.justspeaktoit.android.cloud.CleanupPolicy
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.settings.DictationProfile
import com.justspeaktoit.android.settings.RawConfigurationValues
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
    fun testAudioInput_isSavedAndFallsBackVisiblyWhileDisconnected() {
        val builtIn = AudioInput(AudioInput.id(15, "bottom", "Pixel"), AudioInputKind.BuiltIn, "bottom")
        val usb = AudioInput(AudioInput.id(22, "card=1", "Yeti"), AudioInputKind.Usb, "Yeti")
        h.audioInputs.connected = listOf(builtIn, usb)
        val vm = h.ready()
        assertTrue(h.audioInputs.watching)
        assertEquals(AudioInputChoice.SystemDefault, vm.state.value.audioInputChoice)

        h.onMain { vm.setAudioInput(usb.id) }
        assertEquals(usb.id, h.prefs.audioInputId)
        assertEquals(AudioInputChoice.Selected(usb), vm.state.value.audioInputChoice)

        h.onMain { h.audioInputs.change(listOf(builtIn)) }
        assertEquals(AudioInputChoice.Unavailable(usb.id), vm.state.value.audioInputChoice)
        assertEquals("the saved choice survives a disconnect", usb.id, h.prefs.audioInputId)

        h.onMain { h.audioInputs.change(listOf(builtIn, usb)) }
        assertEquals(AudioInputChoice.Selected(usb), vm.state.value.audioInputChoice)

        h.onMain { vm.setAudioInput(null) }
        assertNull(h.prefs.audioInputId)
        assertEquals(AudioInputChoice.SystemDefault, vm.state.value.audioInputChoice)

        h.clear()
        assertFalse("the device watch ends with the ViewModel", h.audioInputs.watching)
    }

    @Test
    fun testKeepRecordings_movesTheTranscribedRecordingIntoHistory_untilHistoryIsCleared() {
        h.prefs.keepRecordings = true
        val rec = startCloud()
        h.onMain { h.viewModel.stop() }
        val done = h.awaitState { it.dictation is DictationState.Done && it.history.isNotEmpty() }

        val entry = done.history.single()
        assertEquals(HistoryStatus.Completed, entry.status)
        val kept = File(checkNotNull(entry.audioPath))
        assertTrue(kept.exists())
        assertFalse(rec.file.exists())

        h.onMain { h.viewModel.clearHistory() }
        h.awaitState { it.history.isEmpty() }
        assertFalse(kept.exists())
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
    fun testRejectedKey_isMarkedRejectedUntilTheKeyIsSavedAgain() {
        h.cloud.onTranscribe = { throw CloudException(DictationFailure.InvalidKey, "401") }
        startCloud()
        h.onMain { h.viewModel.stop() }
        val failed = h.awaitState { it.dictation is DictationState.Failed }

        assertTrue(CloudProvider.OpenAI in failed.rejectedKeys)
        assertTrue(CloudProvider.OpenAI in failed.keyErrors)

        h.onMain { h.viewModel.saveKey(CloudProvider.OpenAI, "sk-new") }
        val saved = h.awaitState { CloudProvider.OpenAI !in it.rejectedKeys }
        assertFalse(CloudProvider.OpenAI in saved.keyErrors)
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
    fun testCleanupPrompt_isTheSystemInstruction_andTheActiveProfileOverridesIt() {
        h.prefs.cleanupEnabled = true
        h.prefs.cleanupPrompt = "Write in British English."
        h.secrets.write("openrouter.apiKey", "or-test")
        startCloud()
        h.onMain { h.viewModel.stop() }
        h.awaitState { it.cleanup == CleanupStatus.Applied }
        assertEquals(CleanupPolicy.systemPrompt("Write in British English."), h.cloud.cleanupPrompts.single())

        val profile = DictationProfile.create("Formal").copy(cleanupPrompt = "Write formally.")
        h.onMain {
            h.viewModel.saveProfile(profile)
            h.viewModel.chooseProfile(profile.id)
        }
        h.awaitState { it.profile == profile && it.canStart }
        h.onMain { h.viewModel.start() }
        h.awaitState { it.dictation is DictationState.Listening }
        h.onMain { h.viewModel.stop() }
        h.awaitState { it.cleanup == CleanupStatus.Applied && it.history.size == 2 }
        assertEquals(CleanupPolicy.systemPrompt("Write formally."), h.cloud.cleanupPrompts.last())
    }

    @Test
    fun testActiveProfile_setsTheSessionCloudModelAndLanguage_withoutChangingSettings() {
        val groq = CloudCatalog.transcriptionModels.first { it.provider == CloudProvider.Groq }
        h.secrets.write(CloudProvider.Groq.credentialId, "gsk-test")
        val profile = DictationProfile.create("Spanish").withCloudModel(groq).copy(languageId = "es_ES")
        h.prefs.profiles = listOf(profile)
        h.prefs.activeProfileId = profile.id

        val ready = h.ready().state.value
        assertEquals(CloudCatalog.defaultTranscriptionModel, ready.cloudModel)
        assertEquals(groq, ready.sessionCloudModel)
        h.onMain { h.viewModel.start() }
        h.awaitState { it.dictation is DictationState.Listening }
        h.onMain { h.viewModel.stop() }
        h.awaitState { it.dictation is DictationState.Done }
        val request = h.cloud.transcriptions.single()
        assertEquals(groq.catalogId, request.model)
        assertEquals("es-ES", request.languageTag)
        assertEquals(listOf(RecognitionMode.Cloud to groq), h.successes.toList())

        h.onMain { h.viewModel.deleteProfile(profile.id) }
        val cleared = h.awaitState { it.profile == null && it.profiles.isEmpty() }
        assertNull(h.prefs.activeProfileId)
        assertEquals(CloudCatalog.defaultTranscriptionModel, cleared.sessionCloudModel)
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
    fun testLeavingTheApp_withoutTheForegroundService_failsCaptureAndKeepsTheAudioInHistory() {
        h.foreground.refuses = true
        val rec = startCloud()
        h.onMain { h.viewModel.onLeftApp() }
        val failed = h.awaitState {
            it.dictation is DictationState.Failed && !it.releasingMicrophone && it.history.any { e -> e.audioPath != null }
        }

        assertEquals(DictationFailure.LeftApp, (failed.dictation as DictationState.Failed).failure)
        assertEquals(1, rec.stops)
        assertFalse("moved out of the cache", rec.file.exists())
        val entry = failed.history.single()
        assertEquals(HistoryStatus.Failed, entry.status)
        assertEquals(DictationFailure.LeftApp.name, entry.failure)
        assertTrue(File(checkNotNull(entry.audioPath)).exists())
        assertTrue(h.cloud.transcriptions.isEmpty())
    }

    @Test
    fun testLeavingTheApp_withTheForegroundService_keepsRecording_untilTheNotificationsStop() {
        val rec = startCloud()
        assertEquals(listOf(ForegroundPhase.Recording), h.foreground.shown.toList())
        assertEquals("Cloud capture holds audio focus", listOf(true), h.interruptions.starts.toList())

        h.onMain { h.viewModel.onLeftApp() }
        h.onMain { }
        assertTrue(h.viewModel.state.value.dictation is DictationState.Listening)
        assertEquals(0, rec.stops)

        h.onMain { checkNotNull(ForegroundDictation.listener).onStopRequested() }
        h.awaitState { it.dictation is DictationState.Done }
        assertEquals(1, rec.stops)
        assertEquals(listOf(ForegroundPhase.Recording, ForegroundPhase.Finishing), h.foreground.shown.toList())
        assertFalse("hidden once the transcript is in", h.foreground.visible)
        assertFalse(h.interruptions.watching)
        assertNull(ForegroundDictation.listener)
    }

    @Test
    fun testForegroundRefusedAfterLeaving_endsCaptureAsLeftApp() {
        val rec = startCloud()
        h.onMain { h.viewModel.onLeftApp() }
        h.onMain { checkNotNull(ForegroundDictation.listener).onForegroundRefused() }
        val failed = h.awaitState { it.dictation is DictationState.Failed && !it.releasingMicrophone }

        assertEquals(DictationFailure.LeftApp, (failed.dictation as DictationState.Failed).failure)
        assertEquals(1, rec.stops)
    }

    @Test
    fun testTransientFocusLoss_pausesCloudCapture_andFocusGainResumesIt() {
        val rec = startCloud()
        h.onMain { h.interruptions.signal(InterruptionSignal.FocusLostTransient) }
        assertTrue(h.awaitState { it.paused }.paused)
        assertFalse(rec.writing)
        assertEquals(ForegroundPhase.Paused, h.foreground.shown.last())

        h.onMain { h.interruptions.signal(InterruptionSignal.FocusGained) }
        h.awaitState { !it.paused }
        assertTrue(rec.writing)
        assertEquals(ForegroundPhase.Recording, h.foreground.shown.last())
        assertTrue(h.viewModel.state.value.dictation is DictationState.Listening)
    }

    @Test
    fun testCallDuringCloudCapture_endsItAndKeepsTheAudioToTranscribeLater() {
        val rec = startCloud()
        h.onMain { h.interruptions.signal(InterruptionSignal.CallStarted) }
        val failed = h.awaitState {
            it.dictation is DictationState.Failed && !it.releasingMicrophone && it.history.any { e -> e.audioPath != null }
        }

        assertEquals(DictationFailure.InterruptedByCall, (failed.dictation as DictationState.Failed).failure)
        assertEquals(1, rec.stops)
        assertTrue(h.cloud.transcriptions.isEmpty())
        assertFalse(h.foreground.visible)

        h.onMain { h.viewModel.transcribeHistoryEntry(failed.history.single().id) }
        val done = h.awaitState { it.history.singleOrNull()?.status == HistoryStatus.Completed }
        assertEquals("hello world", done.history.single().text)
    }

    @Test
    fun testHeadsetChangeDuringRecognition_keepsTheUnfinishedText() {
        h.prefs.chosenMode = RecognitionMode.SpeechService
        val vm = h.ready()
        h.onMain { vm.start() }
        h.onMain { checkNotNull(h.engine.onEvent)(DictationEvent.Ready) }
        h.onMain { checkNotNull(h.engine.onEvent)(DictationEvent.Partial("half a sentence")) }
        assertEquals("the recogniser manages its own focus", listOf(false), h.interruptions.starts.toList())

        h.onMain { h.interruptions.signal(InterruptionSignal.InputDeviceChanged) }
        val failed = h.awaitState { it.dictation is DictationState.Failed && it.history.isNotEmpty() }

        val dictation = failed.dictation as DictationState.Failed
        assertEquals(DictationFailure.AudioDeviceChanged, dictation.failure)
        assertEquals("half a sentence", dictation.unfinishedText)
        assertEquals("half a sentence", failed.history.single().text)
        assertEquals(1, h.engine.cancels)
    }

    @Test
    fun testClosingTheScreenMidRecording_recoversTheAudioOnTheNextLoad() {
        val rec = startCloud()
        h.clear()
        val end = System.currentTimeMillis() + ViewModelHarness.TIMEOUT_MS
        while ((rec.stops == 0 || h.retirement.pendingOrphans > 0) && System.currentTimeMillis() < end) {
            Thread.sleep(5)
        }
        assertTrue("kept in the cache until History recovers it", rec.file.exists())

        val next = ViewModelHarness(folder.root, h.retirement, h.historyFile)
        try {
            val entry = next.awaitState { it.history.isNotEmpty() }.history.single()
            assertEquals(DictationFailure.RecordingRecovered.name, entry.failure)
            assertTrue(File(checkNotNull(entry.audioPath)).exists())
            assertFalse(rec.file.exists())
        } finally {
            next.close()
        }
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
    fun testSilenceAutoStop_stopsAndTranscribesOnceTheQuietLastsTheSetDuration() {
        h.onMain { h.viewModel.setSilence(SilenceSettings(enabled = true, durationSeconds = 1.0)) }
        assertEquals(SilenceSettings(enabled = true, durationSeconds = 1.0), h.prefs.silence)
        val rec = startCloud()
        rec.onLevel(CaptureLevel(0f, 0.01, 0.1))
        rec.onLevel(CaptureLevel(0f, 0.5, 0.2))
        rec.onLevel(CaptureLevel(0f, 0.01, 0.3))
        rec.onLevel(CaptureLevel(0f, 0.01, 1.2))
        h.onMain { }
        h.onMain { }
        assertTrue(h.viewModel.state.value.dictation is DictationState.Listening)

        rec.onLevel(CaptureLevel(0f, 0.01, 1.3))
        val done = h.awaitState { it.dictation is DictationState.Done }
        assertEquals("hello world", (done.dictation as DictationState.Done).transcript)
        assertEquals(1, rec.stops)
    }

    @Test
    fun testSilenceAutoStop_isOffByDefault() {
        val rec = startCloud()
        rec.onLevel(CaptureLevel(0f, 0.0, 0.1))
        rec.onLevel(CaptureLevel(0f, 0.0, 30.0))
        h.onMain { }
        h.onMain { }
        assertTrue(h.viewModel.state.value.dictation is DictationState.Listening)
        assertEquals(0, rec.stops)
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
    fun testClear_closesEngineAndKeepsTheRecordingForRecovery() {
        val rec = startCloud()
        h.clear()

        assertTrue(h.engine.closed)
        ViewModelHarness.await(rec.stopped)
        awaitRetired()
        assertEquals(listOf(rec.file), h.retirement.recoverable(rec.file.parentFile!!))
        // Callbacks from the released recording reach nothing.
        rec.onLimitReached()
        rec.onCaptureFailed()
        Thread.sleep(50)
        assertEquals(1, h.recorders.created.size)
        assertTrue(h.cloud.transcriptions.isEmpty())
    }

    @Test
    fun testClear_whileTheRecorderStopStalls_returnsAtOnceAndKeepsTheRecordingWhenItUnblocks() {
        val gate = CountDownLatch(1)
        h.recorders.stopGate = gate
        val rec = startCloud()

        h.clear()
        ViewModelHarness.await(rec.stopEntered)
        assertTrue("the main thread is free while the stop stalls", h.onMain { true })
        assertTrue(rec.file.exists())

        gate.countDown()
        awaitRetired()
        assertTrue(rec.file.exists())
        assertEquals(listOf(rec.file), h.retirement.recoverable(rec.file.parentFile!!))
    }

    private fun awaitRetired() {
        val end = System.currentTimeMillis() + ViewModelHarness.TIMEOUT_MS
        while (h.retirement.pendingOrphans > 0 && System.currentTimeMillis() < end) Thread.sleep(5)
        assertEquals(0, h.retirement.pendingOrphans)
    }

    @Test
    fun testApplyConfiguration_routesEveryKeyThroughItsOwner() {
        val vm = h.ready()
        val cloud = CloudCatalog.transcriptionModels.last()
        val cleanup = CloudCatalog.cleanupModels.last()
        val language = DictationLanguages.all.last().id
        val changes = mapOf(
            "chosen_mode" to null,
            "cloud_model" to cloud.catalogId,
            "preferredLocale" to language,
            "personal_corrections" to mapOf("Ada" to "ada, adder"),
            "cleanup_enabled" to true,
            "cleanup_model" to cleanup.selectionId,
            "keepAudioOnCancel" to false,
            "history_retention" to "Forever",
        )
        var applied = false
        h.onMain { applied = vm.applyConfiguration(changes) }

        assertTrue(applied)
        assertEquals(changes, RawConfigurationValues.of(vm.state.value))
        assertNull(h.prefs.chosenMode)
        assertEquals(cloud.catalogId, h.prefs.cloudModelId)
        assertEquals(language, h.prefs.languageId)
        assertEquals(listOf(CorrectionRule("Ada", listOf("ada", "adder"))), h.prefs.corrections)
        assertTrue(h.prefs.cleanupEnabled)
        assertEquals(cleanup.selectionId, h.prefs.cleanupModelId)
        assertFalse(h.prefs.keepAudioOnCancel)
        assertEquals(Retention.Forever, h.prefs.retention)
    }

    @Test
    fun testApplyConfigurationWhileDictating_changesNothing() {
        startCloud()
        val vm = h.viewModel
        val before = h.prefs.retention
        var applied = true
        h.onMain { applied = vm.applyConfiguration(mapOf("history_retention" to "Week")) }
        assertFalse(applied)
        assertEquals(before, h.prefs.retention)
    }
}
