package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.WavFormat
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

    /** A recording whose header was never written, as a process that died mid-recording leaves it. */
    private fun unfinishedRecording(name: String, audioBytes: Int) =
        File(folder.root, name).apply { writeBytes(ByteArray(WavFormat.HEADER_BYTES + audioBytes)) }

    @Test
    fun testLoad_recoversUnfinishedRecordingsWithARepairedHeader_andDeletesTooShortOnes() = runBlocking {
        val second = WavFormat.BYTES_PER_SECOND
        val recording = unfinishedRecording("dictation-a.wav", second + 1)
        val blip = unfinishedRecording("dictation-b.wav", 100)

        history().load(Retention.Month) { listOf(recording, blip) }.join()

        val entry = latest.single()
        assertEquals(HistoryStatus.Failed, entry.status)
        assertEquals(DictationFailure.RecordingRecovered.name, entry.failure)
        assertEquals(RecognitionMode.Cloud.name, entry.mode)
        val kept = File(checkNotNull(entry.audioPath))
        assertEquals("the odd trailing byte is dropped", (WavFormat.HEADER_BYTES + second).toLong(), kept.length())
        assertEquals(WavFormat.header(second.toLong()).toList(), kept.readBytes().take(WavFormat.HEADER_BYTES))
        assertFalse(recording.exists())
        assertFalse(blip.exists())
    }

    @Test
    fun testRecoveredRecording_withHistoryOff_isDeleted() = runBlocking {
        val recording = unfinishedRecording("dictation-a.wav", WavFormat.BYTES_PER_SECOND)
        history().refresh(Retention.Off) { listOf(recording) }.join()
        assertTrue(latest.isEmpty())
        assertTrue(recordingsDir.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun testAttachAudio_movesAnInterruptedRecordingBesideItsFailedEntry() = runBlocking {
        val history = history()
        val failed = DictationState.Failed(RecognitionMode.Cloud, DictationFailure.InterruptedByCall, "")
        history.recordSession(failed, "openai/gpt-transcribe", Retention.Month)
        val recording = unfinishedRecording("dictation-a.wav", WavFormat.BYTES_PER_SECOND)
        history.attachAudio(recording, history.latestSession, Retention.Month).join()

        val entry = latest.single()
        assertEquals(DictationFailure.InterruptedByCall.name, entry.failure)
        assertEquals("openai/gpt-transcribe", entry.model)
        assertTrue(File(checkNotNull(entry.audioPath)).exists())
        assertFalse(recording.exists())
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
        repeat(100) { history.recordSession(DictationState.Done(RecognitionMode.Cloud, "t$it"), null, Retention.Month) }
        history.clear().join()
        assertEquals((1..100).toList() + 0, published.map { it.first.size })
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
    fun testRecordSession_withAudio_keepsTheRecordingBesideTheEntry() = runBlocking {
        val history = history()
        val source = folder.newFile("dictation.wav").apply { writeText("audio") }
        history.recordSession(DictationState.Done(RecognitionMode.Cloud, "hello"), null, Retention.Month, source)
        history.replaceSessionText("Hello.", cleanedUp = true, Retention.Month)?.join()

        val entry = latest.single()
        assertEquals("Hello.", entry.text)
        assertEquals(File(recordingsDir, "id-1.wav").absolutePath, entry.audioPath)
        assertEquals("audio", File(checkNotNull(entry.audioPath)).readText())
        assertFalse(source.exists())
    }

    @Test
    fun testRecordSession_withHistoryOffOrNoSession_deletesTheAudio() = runBlocking {
        val history = history()
        val off = folder.newFile("off.wav").apply { writeText("audio") }
        history.recordSession(DictationState.Done(RecognitionMode.Cloud, "hello"), null, Retention.Off, off)?.join()
        val idle = folder.newFile("idle.wav").apply { writeText("audio") }
        assertNull(history.recordSession(DictationState.Idle, null, Retention.Month, idle))

        assertTrue(latest.isEmpty())
        assertFalse(off.exists())
        assertFalse(idle.exists())
        assertTrue(recordingsDir.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun testClearKeepingRecordings_keepsOnlyEntriesWithAudio() = runBlocking {
        val history = history()
        history.recordSession(DictationState.Done(RecognitionMode.Cloud, "text only"), null, Retention.Month)
        val source = folder.newFile("dictation.wav").apply { writeText("audio") }
        history.recordSession(DictationState.Done(RecognitionMode.Cloud, "with audio"), null, Retention.Month, source)
        history.clear(keepRecordings = true, Retention.Month).join()

        val entry = latest.single()
        assertEquals("with audio", entry.text)
        assertTrue(File(checkNotNull(entry.audioPath)).exists())

        history.clear().join()
        assertTrue(latest.isEmpty())
        assertTrue(recordingsDir.listFiles().orEmpty().isEmpty())
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
