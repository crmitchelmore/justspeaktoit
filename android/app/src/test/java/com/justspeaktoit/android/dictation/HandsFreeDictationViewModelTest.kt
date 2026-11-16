package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.WavFormat
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

/** Hands-free dictation (#1632) through the real ViewModel, with a microphone the test feeds. */
class HandsFreeDictationViewModelTest {
    @get:Rule val folder = TemporaryFolder()

    private lateinit var h: ViewModelHarness
    private val audio = SyntheticAudio()

    @Before
    fun setUp() {
        h = ViewModelHarness(folder.root)
        h.prefs.handsFreeEnabled = true
    }

    @After
    fun tearDown() {
        h.close()
    }

    private fun arm(): DictationViewModel {
        val vm = h.ready()
        h.onMain { vm.start() }
        h.awaitState { it.handsFree == HandsFreeStatus.Listening }
        return vm
    }

    private fun speak() {
        h.handsFreeMicrophone.feed(audio.chunks(1.0))
        h.handsFreeMicrophone.feed(audio.chunks(0.6, tone = SyntheticAudio.voice(0.1)))
        h.awaitState { it.handsFree == HandsFreeStatus.Recording && it.dictation is DictationState.Listening }
    }

    @Test
    fun testTap_listensWithoutRecording() {
        arm()

        assertTrue(h.handsFreeMicrophone.open)
        assertTrue(h.recorders.created.isEmpty())
        assertEquals(DictationState.Idle, h.viewModel.state.value.dictation)
        assertEquals(listOf(ForegroundPhase.Listening), h.foreground.shown.toList())
        assertEquals(listOf("HandsFreeDictation"), h.resources.holds.value.map { it.owner })
        h.handsFreeMicrophone.feed(audio.chunks(5.0))
        h.onMain { }
        assertEquals(HandsFreeStatus.Listening, h.viewModel.state.value.handsFree)
    }

    @Test
    fun testSpeech_recordsWithThePreRoll_stopsOnSilence_andListensAgain() {
        arm()
        speak()
        assertTrue("the recording takes the hands-free audio", h.recorders.created.isEmpty())
        h.handsFreeMicrophone.feed(audio.chunks(3.0))

        val done = h.awaitState { it.dictation is DictationState.Done && it.handsFree == HandsFreeStatus.Listening }
        h.onMain { }

        assertEquals(DictationState.Done(RecognitionMode.Cloud, "hello world"), done.dictation)
        val sent = h.cloud.sentAudio.single()
        val samples = ByteBuffer.wrap(sent, WavFormat.HEADER_BYTES, sent.size - WavFormat.HEADER_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val pcm = ShortArray(samples.remaining()).also { samples.get(it) }
        assertTrue("it starts with the quiet before speech", pcm.take(WavFormat.SAMPLE_RATE / 10).all { abs(it.toInt()) < 100 })
        assertTrue("then the speech", pcm.any { abs(it.toInt()) > 1_000 })
        assertTrue(h.handsFreeMicrophone.open)
        assertEquals(1, h.handsFreeMicrophone.starts)
        assertTrue("the service stays up between recordings", h.foreground.visible)
        assertEquals(ForegroundPhase.Listening, h.foreground.shown.last())
        assertTrue(ForegroundPhase.Recording in h.foreground.shown)

        speak()
        assertTrue(h.recorders.created.isEmpty())
    }

    @Test
    fun testTurnOffWhileRecording_transcribesAndReleasesTheMicrophone() {
        val vm = arm()
        speak()

        h.onMain { vm.turnOffHandsFree() }
        val done = h.awaitState { it.dictation is DictationState.Done && !it.releasingMicrophone }

        assertEquals(HandsFreeStatus.Off, done.handsFree)
        assertEquals(1, h.cloud.transcriptions.size)
        assertFalse(h.handsFreeMicrophone.open)
        h.onMain { }
        assertFalse(h.foreground.visible)
        assertTrue(h.resources.holds.value.isEmpty())
    }

    @Test
    fun testTurnOffWhileListening_releasesEverything() {
        val vm = arm()

        h.onMain { vm.turnOffHandsFree() }

        assertEquals(HandsFreeStatus.Off, vm.state.value.handsFree)
        assertFalse(h.handsFreeMicrophone.open)
        assertFalse(h.foreground.visible)
        assertNull(ForegroundDictation.listener)
        assertTrue(h.resources.holds.value.isEmpty())
        assertTrue(h.prefs.handsFreeEnabled)
    }

    @Test
    fun testNotificationStopWhileListening_turnsHandsFreeOff() {
        arm()

        h.onMain { checkNotNull(ForegroundDictation.listener).onStopRequested() }

        assertEquals(HandsFreeStatus.Off, h.viewModel.state.value.handsFree)
        assertFalse(h.handsFreeMicrophone.open)
    }

    @Test
    fun testReleasingTheHoldInSettings_turnsHandsFreeOff() {
        val vm = arm()

        h.onMain { vm.releaseResource(h.resources.holds.value.single().id) }

        assertEquals(HandsFreeStatus.Off, vm.state.value.handsFree)
        assertFalse(h.handsFreeMicrophone.open)
    }

    @Test
    fun testSwitchingTheSettingOff_stopsListening() {
        val vm = arm()

        h.onMain { vm.setHandsFree(false) }

        assertFalse(h.prefs.handsFreeEnabled)
        assertEquals(HandsFreeStatus.Off, vm.state.value.handsFree)
        assertFalse(h.handsFreeMicrophone.open)
        assertFalse(vm.state.value.armsHandsFree)
    }

    @Test
    fun testMicrophoneFailure_stopsHandsFree() {
        arm()

        h.handsFreeMicrophone.fail()
        val stopped = h.awaitState { it.handsFree == HandsFreeStatus.Stopped }
        h.onMain { }

        assertFalse(stopped.handsFreeArmed)
        assertFalse(h.handsFreeMicrophone.open)
        assertFalse(h.foreground.visible)
    }

    @Test
    fun testMicrophoneThatCannotOpen_showsStoppedAndHoldsNothing() {
        h.handsFreeMicrophone.opens = false
        val vm = h.ready()

        h.onMain { vm.start() }

        assertEquals(HandsFreeStatus.Stopped, vm.state.value.handsFree)
        assertTrue(h.foreground.shown.isEmpty())
        assertTrue(h.resources.holds.value.isEmpty())
    }

    @Test
    fun testLeavingTheAppWithoutTheService_stopsListening() {
        h.foreground.refuses = true
        val vm = arm()

        h.onMain { vm.onLeftApp() }

        assertEquals(HandsFreeStatus.Stopped, vm.state.value.handsFree)
        assertFalse(h.handsFreeMicrophone.open)
    }

    @Test
    fun testHandsFreeOff_recordsAtOnce() {
        h.prefs.handsFreeEnabled = false
        val vm = h.ready()

        h.onMain { vm.start() }
        h.awaitState { it.dictation is DictationState.Listening }

        assertEquals(0, h.handsFreeMicrophone.starts)
        assertEquals(1, h.recorders.created.size)
    }
}
