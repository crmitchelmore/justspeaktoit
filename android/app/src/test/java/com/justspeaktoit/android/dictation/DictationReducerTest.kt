package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.dictation.DictationEvent.Cancelled
import com.justspeaktoit.android.dictation.DictationEvent.Error
import com.justspeaktoit.android.dictation.DictationEvent.Final
import com.justspeaktoit.android.dictation.DictationEvent.Partial
import com.justspeaktoit.android.dictation.DictationEvent.Ready
import com.justspeaktoit.android.dictation.DictationEvent.Start
import com.justspeaktoit.android.dictation.DictationEvent.StopRequested
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationReducerTest {
    private val mode = RecognitionMode.OnDevice

    private fun run(vararg events: DictationEvent): DictationState =
        events.fold(DictationState.Idle as DictationState, DictationReducer::reduce)

    @Test
    fun testStartStopFinal_producesDoneWithTrimmedTranscript() {
        val state = run(
            Start(mode), Ready, Partial("hello"), Partial("hello world"), StopRequested, Final(" hello world "),
        )
        assertEquals(DictationState.Done(mode, "hello world"), state)
    }

    @Test
    fun testPartials_replaceRatherThanAppend() {
        val state = run(Start(mode), Ready, Partial("one"), Partial("one two"))
        assertEquals(DictationState.Listening(mode, "one two"), state)
    }

    @Test
    fun testEmptyFinal_isFailureNotSuccess() {
        val state = run(Start(mode), Ready, StopRequested, Final("   "))
        assertEquals(DictationState.Failed(mode, DictationFailure.NoSpeech, ""), state)
    }

    @Test
    fun testErrorAfterPartials_keepsTextAsUnfinished() {
        val state = run(Start(mode), Ready, Partial("half a sent"), Error(DictationFailure.Network))
        assertEquals(DictationState.Failed(mode, DictationFailure.Network, "half a sent"), state)
    }

    @Test
    fun testEmptyFinalAfterPartials_keepsPartialsAsUnfinished() {
        val state = run(Start(mode), Partial("draft"), StopRequested, Final(""))
        assertEquals(DictationState.Failed(mode, DictationFailure.NoSpeech, "draft"), state)
    }

    @Test
    fun testCancel_returnsToIdleAndDropsText() {
        assertEquals(DictationState.Idle, run(Start(mode), Ready, Partial("secret"), Cancelled))
    }

    @Test
    fun testLateEventsAfterCompletion_areIgnored() {
        val done = run(Start(mode), Ready, Final("kept"))
        assertEquals(done, DictationReducer.reduce(done, Partial("late")))
        assertEquals(done, DictationReducer.reduce(done, Final("late")))
        assertEquals(done, DictationReducer.reduce(done, Error(DictationFailure.Client)))
        assertEquals(done, DictationReducer.reduce(done, Cancelled))
    }

    @Test
    fun testStartWhileActive_isIgnored() {
        val listening = run(Start(mode), Ready)
        assertEquals(listening, DictationReducer.reduce(listening, Start(RecognitionMode.SpeechService)))
    }

    @Test
    fun testStopBeforeReady_finishesWithoutText() {
        assertEquals(DictationState.Finishing(mode, ""), run(Start(mode), StopRequested))
    }

    @Test
    fun testNewSessionAfterFailure_startsCleanly() {
        val state = run(Start(mode), Error(DictationFailure.Audio), Start(RecognitionMode.SpeechService))
        assertEquals(DictationState.Starting(RecognitionMode.SpeechService), state)
    }

    @Test
    fun testIsActive_coversOnlyInFlightStates() {
        assertTrue(DictationState.Starting(mode).isActive)
        assertTrue(DictationState.Listening(mode, "").isActive)
        assertTrue(DictationState.Finishing(mode, "").isActive)
        assertFalse(DictationState.Idle.isActive)
        assertFalse(DictationState.Done(mode, "x").isActive)
        assertFalse(DictationState.Failed(mode, DictationFailure.Unknown, "").isActive)
    }

    @Test
    fun testRecognizerErrorCodes_mapToFailures() {
        val expected = mapOf(
            1 to DictationFailure.NetworkTimeout,
            2 to DictationFailure.Network,
            3 to DictationFailure.Audio,
            4 to DictationFailure.Server,
            5 to DictationFailure.Client,
            6 to DictationFailure.NoSpeech,
            7 to DictationFailure.NoMatch,
            8 to DictationFailure.RecognizerBusy,
            9 to DictationFailure.PermissionDenied,
            10 to DictationFailure.TooManyRequests,
            11 to DictationFailure.Server,
            12 to DictationFailure.LanguageNotSupported,
            13 to DictationFailure.LanguageUnavailable,
            99 to DictationFailure.Unknown,
        )
        expected.forEach { (code, failure) -> assertEquals("code $code", failure, RecognizerErrors.failureFor(code)) }
    }
}
