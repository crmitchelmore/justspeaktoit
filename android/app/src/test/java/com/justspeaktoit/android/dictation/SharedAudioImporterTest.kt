package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.SharedAudio
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean

class SharedAudioImporterTest {
    @get:Rule val folder = TemporaryFolder()

    private val importer by lazy {
        SharedAudioImporter(CloudCapture(FakeRecorders(), folder.root, Dispatchers.IO), deadlineMs = 200)
    }
    private val target by lazy { folder.root.resolve("shared") }

    private fun import(declared: String?, providerType: String?, open: () -> InputStream?) =
        runBlocking { importer.import(declared, target, { providerType }, open) }

    private fun failure(block: () -> Unit) = assertThrows(CloudException::class.java, block).failure

    @Test
    fun testGenericDeclaredType_usesTheProvidersTypeAndCopiesTheAudio() {
        val format = import("audio/*", "audio/mp4") { ByteArrayInputStream(byteArrayOf(1, 2, 3)) }
        assertEquals(SharedAudio.Format("m4a", "audio/mp4"), format)
        assertEquals(listOf<Byte>(1, 2, 3), target.readBytes().toList())
    }

    @Test
    fun testUnsupportedFormat_failsBeforeOpening() {
        val opened = AtomicBoolean(false)
        val failure = failure {
            import("audio/amr", "audio/amr") {
                opened.set(true)
                null
            }
        }
        assertEquals(DictationFailure.UnsupportedAudio, failure)
        assertFalse(opened.get())
    }

    @Test
    fun testUnreadableItem_failsAsIo() {
        assertThrows(IOException::class.java) { import("audio/wav", null) { null } }
    }

    @Test
    fun testAudioOverTheLimit_failsAsTooLarge() {
        val endless = object : InputStream() {
            override fun read() = 0

            override fun read(b: ByteArray, off: Int, len: Int) = len
        }
        val slow = SharedAudioImporter(CloudCapture(FakeRecorders(), folder.root, Dispatchers.IO), 60_000)
        val error = assertThrows(CloudException::class.java) {
            runBlocking { slow.import("audio/wav", target, { null }, { endless }) }
        }
        assertEquals(DictationFailure.AudioTooLarge, error.failure)
    }

    @Test
    fun testStalledSender_isClosedAtTheDeadlineAndFailsAsAudio() {
        val closed = AtomicBoolean(false)
        val stalled = object : InputStream() {
            override fun read(): Int {
                while (!closed.get()) Thread.sleep(5)
                throw IOException("closed")
            }

            override fun close() {
                closed.set(true)
            }
        }
        assertEquals(DictationFailure.Audio, failure { import("audio/wav", null) { stalled } })
        assertTrue(closed.get())
    }
}
