package com.justspeaktoit.android.dictation

import android.media.AudioDeviceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioInterruptionsTest {
    private fun decide(signal: InterruptionSignal, mode: RecognitionMode = RecognitionMode.Cloud, paused: Boolean = false) =
        InterruptionPolicy.decide(signal, mode, paused)

    @Test
    fun testTransientFocusLoss_pausesOnlyCloudCapture() {
        assertEquals(InterruptionAction.Pause, decide(InterruptionSignal.FocusLostTransient))
        assertEquals(InterruptionAction.None, decide(InterruptionSignal.FocusLostTransient, paused = true))
        assertEquals(
            "the recogniser cannot pause",
            InterruptionAction.None,
            decide(InterruptionSignal.FocusLostTransient, RecognitionMode.SpeechService),
        )
    }

    @Test
    fun testFocusGain_resumesOnlyAPausedSession() {
        assertEquals(InterruptionAction.Resume, decide(InterruptionSignal.FocusGained, paused = true))
        assertEquals(InterruptionAction.None, decide(InterruptionSignal.FocusGained))
    }

    @Test
    fun testCallsFocusLossAndRouteChanges_stopEveryModeWithTheirOwnMessage() {
        RecognitionMode.entries.forEach { mode ->
            assertEquals(
                InterruptionAction.Stop(DictationFailure.InterruptedByCall),
                decide(InterruptionSignal.CallStarted, mode),
            )
            assertEquals(InterruptionAction.Stop(DictationFailure.AudioFocusLost), decide(InterruptionSignal.FocusLost, mode))
            assertEquals(
                InterruptionAction.Stop(DictationFailure.AudioDeviceChanged),
                decide(InterruptionSignal.InputDeviceChanged, mode, paused = true),
            )
        }
    }

    @Test
    fun testRouteChange_ignoresTheDevicesReportedOnRegistrationAndBuiltInInputs() {
        val headset = InputDevice(7, AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
        val builtIn = InputDevice(1, AudioDeviceInfo.TYPE_BUILTIN_MIC)
        val known = setOf(1, 7)

        assertFalse("registration replays known devices", InputRoutes.isRouteChange(known, listOf(builtIn, headset), true))
        assertTrue("headset removed", InputRoutes.isRouteChange(known, listOf(headset), false))
        assertTrue(
            "headset connected",
            InputRoutes.isRouteChange(setOf(1), listOf(InputDevice(9, AudioDeviceInfo.TYPE_WIRED_HEADSET)), true),
        )
        assertFalse(
            "a built-in input is not a route change",
            InputRoutes.isRouteChange(setOf(7), listOf(InputDevice(2, AudioDeviceInfo.TYPE_TELEPHONY)), true),
        )
    }

    @Test
    fun testForegroundPhase_coversCaptureUploadAndSaving() {
        val mode = RecognitionMode.Cloud
        assertEquals(ForegroundPhase.Recording, foregroundPhase(SessionState(DictationState.Starting(mode))))
        assertEquals(ForegroundPhase.Recording, foregroundPhase(SessionState(DictationState.Listening(mode, ""))))
        assertEquals(
            ForegroundPhase.Paused,
            foregroundPhase(SessionState(DictationState.Listening(mode, ""), paused = true)),
        )
        assertEquals(ForegroundPhase.Finishing, foregroundPhase(SessionState(DictationState.Finishing(mode, ""))))
        val failed = DictationState.Failed(mode, DictationFailure.InterruptedByCall, "")
        assertEquals(
            "still saving the recording",
            ForegroundPhase.Finishing,
            foregroundPhase(SessionState(failed, releasingMicrophone = true)),
        )
        assertNull(foregroundPhase(SessionState(failed)))
        assertNull(foregroundPhase(SessionState()))
    }
}
