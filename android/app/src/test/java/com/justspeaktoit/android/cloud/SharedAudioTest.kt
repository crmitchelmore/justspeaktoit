package com.justspeaktoit.android.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SharedAudioTest {
    @Test
    fun testFormat_mapsCommonTypesToProviderFormats() {
        assertEquals(SharedAudio.Format("mp3", "audio/mpeg"), SharedAudio.format("audio/mpeg"))
        assertEquals(SharedAudio.Format("m4a", "audio/mp4"), SharedAudio.format("audio/x-m4a"))
        assertEquals(SharedAudio.Format("ogg", "audio/ogg"), SharedAudio.format("audio/ogg; codecs=opus"))
        assertEquals(SharedAudio.Format("wav", "audio/wav"), SharedAudio.format("AUDIO/WAV"))
        assertEquals(SharedAudio.Format("flac", "audio/flac"), SharedAudio.format("audio/x-flac"))
    }

    @Test
    fun testFormat_rejectsUnsupportedOrMissingTypes() {
        assertNull(SharedAudio.format("audio/amr"))
        assertNull(SharedAudio.format("audio/aac"))
        assertNull(SharedAudio.format("video/mp4"))
        assertNull(SharedAudio.format(null))
    }
}
