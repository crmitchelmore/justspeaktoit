package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryFile
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.HistoryStore
import com.justspeaktoit.android.history.Retention
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class DictationHistoryTest {
    @get:Rule val folder = TemporaryFolder()

    private class FlakyFile : HistoryFile {
        val memory = MemoryHistoryFile()
        @Volatile var failWrites = false

        override fun read() = memory.read()

        override fun write(text: String) {
            if (failWrites) throw IOException("disk full")
            memory.write(text)
        }

        override fun delete() = memory.delete()
    }

    private val file = FlakyFile()
    private val clock = AtomicLong(System.currentTimeMillis())
    private val ids = AtomicInteger()
    private val store = HistoryStore(file, deleteAudio = { File(it).delete() }, now = clock::get)
    private val recordingsDir by lazy { folder.newFolder("recordings") }
    private val published = CopyOnWriteArrayList<Pair<List<HistoryEntry>, Boolean>>()

    private fun CoroutineScope.history() = DictationHistory(
        store,
        recordingsDir,
        scope = this,
        io = Dispatchers.IO,
        publish = { entries, failed -> published += entries to failed },
        now = { clock.incrementAndGet() },
        newId = { "id-${ids.incrementAndGet()}" },
    )

    private val latest get() = published.last().first

    @Test
    fun testLoad_deletesAudioNoEntryRefersTo() = runBlocking {
        val orphan = File(recordingsDir, "orphan.wav").apply { writeText("x") }
        history().load(Retention.Month).join()
        assertFalse(orphan.exists())
        assertEquals(emptyList<HistoryEntry>(), latest)
    }

    @Test
    fun testSessionEntry_isReplacedInPlaceByCleanupAndRestore() = runBlocking {
        val history = history()
        assertNull(history.recordSession(DictationState.Idle, null, Retention.Month))
        history.recordSession(DictationState.Done(RecognitionMode.Cloud, "hello"), "openai/gpt-transcribe", Retention.Month)
        history.replaceSessionText("Hello.", cleanedUp = true, Retention.Month)
        history.replaceSessionText("hello", cleanedUp = false, Retention.Month)?.join()

        val entry = latest.single()
        assertEquals("hello", entry.text)
        assertFalse(entry.cleanedUp)
        assertEquals("openai/gpt-transcribe", entry.model)
        assertEquals(HistoryStatus.Completed, entry.status)
        assertEquals(listOf(1, 1, 1), published.map { it.first.size })
    }

    @Test
    fun testOnDeviceSession_recordsNoModel_andFailureIsKeptWithItsText() = runBlocking {
        history().recordSession(
            DictationState.Failed(RecognitionMode.OnDevice, DictationFailure.Audio, "half a sen"),
            "openai/gpt-transcribe",
            Retention.Month,
        )?.join()
        val entry = latest.single()
        assertNull(entry.model)
        assertEquals(HistoryStatus.Failed, entry.status)
        assertEquals("half a sen", entry.text)
        assertEquals(DictationFailure.Audio.name, entry.failure)
    }

    @Test
    fun testWritesApplyInCallOrder() = runBlocking {
        val history = history()
        repeat(20) { history.recordSession(DictationState.Done(RecognitionMode.Cloud, "t$it"), null, Retention.Month) }
        history.clear().join()
        assertEquals((1..20).toList() + 0, published.map { it.first.size })
    }

    @Test
    fun testKeepRecording_movesTheAudioIntoHistoryAsACancelledEntry() = runBlocking {
        val source = folder.newFile("dictation.wav").apply { writeText("audio") }
        history().keepRecording(source, "groq/whisper-large-v3-turbo", Retention.Month).join()

        val entry = latest.single()
        assertEquals(HistoryStatus.Cancelled, entry.status)
        assertEquals("groq/whisper-large-v3-turbo", entry.model)
        val kept = File(checkNotNull(entry.audioPath))
        assertEquals(File(recordingsDir, "id-1.wav").absolutePath, kept.absolutePath)
        assertEquals("audio", kept.readText())
        assertFalse(source.exists())
    }

    @Test
    fun testKeepRecording_whoseAudioCannotMove_leavesHistoryUnchanged() = runBlocking {
        val missing = File(folder.root, "gone.wav")
        history().keepRecording(missing, null, Retention.Month).join()
        assertEquals(emptyList<HistoryEntry>(), latest)
        assertFalse(File(recordingsDir, "id-1.wav").exists())
    }

    @Test
    fun testFailedWrite_publishesTheErrorAndIsRetriedByTheNextChange() = runBlocking {
        val history = history()
        file.failWrites = true
        history.recordSession(DictationState.Done(RecognitionMode.Cloud, "kept in memory"), null, Retention.Month)?.join()
        assertTrue(published.last().second)
        assertEquals("kept in memory", latest.single().text)

        file.failWrites = false
        history.refresh(Retention.Month).join()
        assertFalse(published.last().second)
        assertTrue(checkNotNull(file.read()).contains("kept in memory"))
    }
}
