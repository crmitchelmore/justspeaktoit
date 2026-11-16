package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class HistoryRetryTest {
    @get:Rule val folder = TemporaryFolder()

    private val cloud = FakeCloud()
    private val secrets = MemorySecrets("openai.apiKey" to "sk-test")
    private val model = CloudCatalog.transcriptionModel("openai/gpt-transcribe")
    private val retry by lazy {
        HistoryRetry(cloud, secrets, CloudCapture(FakeRecorders(), folder.root, Dispatchers.IO), Dispatchers.IO, 1_000)
    }

    private fun kept(audio: File) = HistoryEntry(
        id = "kept",
        createdAtMs = 1,
        mode = RecognitionMode.Cloud.name,
        model = "groq/whisper-large-v3-turbo",
        status = HistoryStatus.Cancelled,
        text = "",
        audioPath = audio.absolutePath,
    )

    private fun transcribe(entry: HistoryEntry) = runBlocking { retry.transcribe(entry, model, "en-GB") }

    @Test
    fun testSuccess_completesWithTheCurrentModelAndDropsTheAudio() {
        cloud.onTranscribe = { "  kept words \n" }
        val updated = transcribe(kept(folder.newFile("a.wav")))
        assertEquals(HistoryStatus.Completed, updated.status)
        assertEquals("kept words", updated.text)
        assertEquals("openai/gpt-transcribe", updated.model)
        assertNull(updated.failure)
        assertNull(updated.audioPath)
        assertEquals("en-GB", cloud.transcriptions.single().languageTag)
    }

    @Test
    fun testSuccess_whenRecordingsAreKept_keepsTheAudio() {
        cloud.onTranscribe = { "kept words" }
        val audio = folder.newFile("a.wav")
        val updated = runBlocking { retry.transcribe(kept(audio), model, "en-GB", keepAudio = true) }
        assertEquals(HistoryStatus.Completed, updated.status)
        assertEquals(audio.absolutePath, updated.audioPath)
    }

    @Test
    fun testFailures_keepTheAudioAndRecordWhy() {
        val audio = folder.newFile("a.wav")
        cloud.onTranscribe = { "   " }
        assertEquals(DictationFailure.NoSpeech.name, transcribe(kept(audio)).failure)

        cloud.onTranscribe = { throw CloudException(DictationFailure.InvalidKey, "401") }
        val rejected = transcribe(kept(audio))
        assertEquals(DictationFailure.InvalidKey.name, rejected.failure)
        assertEquals(HistoryStatus.Cancelled, rejected.status)
        assertEquals(audio.absolutePath, rejected.audioPath)

        secrets.remove("openai.apiKey")
        assertEquals(DictationFailure.MissingKey.name, transcribe(kept(audio)).failure)
        assertEquals(2, cloud.transcriptions.size)
    }

    @Test
    fun testLiveOnlyModel_failsWithoutUploadingAndKeepsTheAudio() {
        val audio = folder.newFile("a.wav")
        val liveModel = CloudCatalog.liveTranscriptionModels.first()

        val updated = runBlocking { retry.transcribe(kept(audio), liveModel, "en-GB") }

        assertEquals(DictationFailure.LiveOnlyModel.name, updated.failure)
        assertEquals(audio.absolutePath, updated.audioPath)
        assertTrue(audio.exists())
        assertTrue(cloud.transcriptions.isEmpty())
    }

    @Test
    fun testMissingAudio_failsTheEntryWithoutUploading() {
        val updated = transcribe(kept(File(folder.root, "gone.wav")))
        assertEquals(HistoryStatus.Failed, updated.status)
        assertEquals(DictationFailure.Audio.name, updated.failure)
        assertNull(updated.audioPath)
        assertEquals(0, cloud.transcriptions.size)
    }

    @Test
    fun testEntryWithoutAudio_isReturnedUnchanged() {
        val entry = kept(folder.newFile("a.wav")).copy(audioPath = null)
        assertSame(entry, transcribe(entry))
    }

    private val local = FakeLocalTranscriber()
    private val localModels = mutableMapOf<String, File>()
    private val localRetry by lazy {
        HistoryRetry(
            cloud,
            secrets,
            CloudCapture(FakeRecorders(), folder.root, Dispatchers.IO),
            Dispatchers.IO,
            1_000,
            DownloadedTranscription({ localModels[it] }, local),
        )
    }

    private fun downloaded(audio: File) = kept(audio).copy(
        mode = RecognitionMode.Downloaded.name,
        model = BASE_MODEL,
        status = HistoryStatus.Failed,
        failure = DictationFailure.ModelMissing.name,
    )

    @Test
    fun testDownloadedRetry_transcribesOnThePhoneWithTheChosenModel() {
        val model = folder.newFile("ggml-small.bin")
        localModels[SMALL_MODEL] = model
        local.onTranscribe = { " on the phone " }
        val audio = folder.newFile("a.wav")

        val updated = runBlocking { localRetry.transcribeLocal(downloaded(audio), SMALL_MODEL, "de-DE") }

        assertEquals(HistoryStatus.Completed, updated.status)
        assertEquals("on the phone", updated.text)
        assertEquals(SMALL_MODEL, updated.model)
        assertEquals(RecognitionMode.Downloaded.name, updated.mode)
        assertNull(updated.audioPath)
        assertEquals(FakeLocalTranscriber.Call(model, audio, "de-DE"), local.calls.single())
        assertTrue("a downloaded retry never uploads", cloud.transcriptions.isEmpty())
    }

    @Test
    fun testDownloadedRetry_withoutTheModel_keepsTheEntryAndItsAudio() {
        val entry = downloaded(folder.newFile("a.wav")).copy(failure = DictationFailure.LocalModelFailed.name)

        val updated = runBlocking { localRetry.transcribeLocal(entry, BASE_MODEL, "en-GB") }

        assertEquals(entry.copy(failure = DictationFailure.ModelMissing.name), updated)
        assertTrue(local.calls.isEmpty())
        assertTrue(cloud.transcriptions.isEmpty())
    }

    @Test
    fun testUsesDownloadedModel_onlyForDownloadedEntriesAndRecoveriesInDownloadedMode() {
        val audio = folder.newFile("a.wav")
        assertTrue(HistoryRetry.usesDownloadedModel(downloaded(audio), RecognitionMode.Cloud))
        assertFalse(HistoryRetry.usesDownloadedModel(kept(audio), RecognitionMode.Downloaded))
        val recovered = kept(audio).copy(model = null)
        assertTrue(HistoryRetry.usesDownloadedModel(recovered, RecognitionMode.Downloaded))
        assertFalse(HistoryRetry.usesDownloadedModel(recovered, RecognitionMode.Cloud))
    }

    private companion object {
        const val BASE_MODEL = "local/whisperkit/base"
        const val SMALL_MODEL = "local/whisperkit/small"
    }
}
