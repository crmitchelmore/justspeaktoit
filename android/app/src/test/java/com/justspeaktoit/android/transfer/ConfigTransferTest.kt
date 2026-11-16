package com.justspeaktoit.android.transfer

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.dictation.MemoryHistoryFile
import com.justspeaktoit.android.dictation.MemoryPrefs
import com.justspeaktoit.android.dictation.MemorySecrets
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.history.HistoryStore
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.security.SecretStore
import com.justspeaktoit.android.settings.DictationProfile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException

class ConfigTransferTest {
    @get:Rule val folder = TemporaryFolder()

    private val nowMs = System.currentTimeMillis()
    private val openAi = CloudProvider.OpenAI.credentialId
    private val groq = CloudProvider.Groq.credentialId

    private fun sourcePrefs() = MemoryPrefs(
        chosenMode = RecognitionMode.OnDevice,
        cloudModelId = CloudCatalog.transcriptionModels.last().catalogId,
        cleanupModelId = CloudCatalog.cleanupModels.last().selectionId,
        cleanupEnabled = true,
        retention = Retention.Forever,
        keepAudioOnCancel = false,
        languageId = "en_GB",
        corrections = listOf(CorrectionRule("Kubernetes", listOf("cooper netties", "cube a nets"))),
        cleanupPrompt = "Keep it short.",
        profiles = listOf(PROFILE),
        activeProfileId = PROFILE.id,
    )

    private val keptAudio by lazy { folder.newFile("kept.wav").apply { writeBytes(ByteArray(2048) { it.toByte() }) } }

    private fun sourceHistory(): List<HistoryEntry> {
        val audio = keptAudio
        return listOf(
            HistoryEntry(FIRST, nowMs - 1_000, RecognitionMode.Cloud.name, "openai/gpt-transcribe", HistoryStatus.Completed, "Hello there"),
            HistoryEntry(
                SECOND, nowMs - 60_000, RecognitionMode.OnDevice.name, null, HistoryStatus.Failed, "Half a",
                failure = "No network", audioPath = audio.absolutePath,
            ),
        )
    }

    private fun export(
        prefs: MemoryPrefs = sourcePrefs(),
        history: List<HistoryEntry> = sourceHistory(),
        secrets: SecretStore = MemorySecrets(openAi to "sk-open", groq to "gsk-groq"),
        includeCredentials: Boolean = false,
    ): ArchiveContents {
        val archive = folder.newFile()
        archive.outputStream().use { ConfigExporter.export(it, prefs, history, secrets, includeCredentials, nowMs) }
        return ConfigArchiveReader.read(archive, folder.newFolder())
    }

    private fun applier(prefs: MemoryPrefs, secrets: SecretStore, store: HistoryStore) = ConfigImportApplier(
        prefs = prefs,
        secrets = secrets,
        recordingsDir = File(folder.root, "recordings"),
        io = Dispatchers.Unconfined,
        commitHistory = { retention, change -> store.replaceAll(retention, change) },
    )

    @Test
    fun export_thenImportIntoAnEmptyPhone_restoresEverything() = runBlocking {
        val contents = export(includeCredentials = true)
        val prefs = MemoryPrefs()
        val secrets = MemorySecrets()
        val store = HistoryStore(MemoryHistoryFile())
        val plan = ConfigImporter.plan(contents, prefs, store.load(prefs.retention), secrets.names(), nowMs)

        val counts = plan.preview.categories.associateBy { it.category }
        assertEquals(2, counts.getValue(TransferCategory.History).added)
        assertEquals(1, counts.getValue(TransferCategory.Recordings).added)
        assertEquals(1, counts.getValue(TransferCategory.Profiles).added)
        assertEquals(1, counts.getValue(TransferCategory.Vocabulary).added)
        assertEquals(2, plan.preview.credentials)
        assertEquals(emptyList<String>(), plan.preview.notices)

        assertTrue(applier(prefs, secrets, store).applyPlan(plan, includeCredentials = true))

        val expected = sourcePrefs()
        assertEquals(expected.chosenMode, prefs.chosenMode)
        assertEquals(expected.cloudModelId, prefs.cloudModelId)
        assertEquals(expected.cleanupModelId, prefs.cleanupModelId)
        assertEquals(expected.cleanupEnabled, prefs.cleanupEnabled)
        assertEquals(expected.retention, prefs.retention)
        assertEquals(expected.keepAudioOnCancel, prefs.keepAudioOnCancel)
        assertEquals(expected.languageId, prefs.languageId)
        assertEquals(expected.cleanupPrompt, prefs.cleanupPrompt)
        assertEquals(expected.corrections, prefs.corrections)
        assertEquals(listOf(PROFILE), prefs.profiles.map { it.copy(source = null) })
        assertEquals(PROFILE.id, prefs.activeProfileId)
        assertEquals("sk-open", secrets.read(openAi))
        assertEquals("gsk-groq", secrets.read(groq))

        val history = store.load(prefs.retention)
        assertEquals(sourceHistory().map { it.copy(audioPath = null) }, history.map { it.copy(audioPath = null) })
        val audio = File(history.single { it.id == SECOND }.audioPath!!)
        assertTrue(audio.startsWith(File(folder.root, "recordings")))
        assertEquals(2048L, audio.length())
    }

    @Test
    fun reimportingTheSameExport_changesNothing() = runBlocking {
        val prefs = sourcePrefs()
        val history = sourceHistory()
        val secrets = MemorySecrets(openAi to "sk-open")
        val plan = ConfigImporter.plan(export(prefs, history, secrets, includeCredentials = false), prefs, history, secrets.names(), nowMs)

        assertFalse(plan.preview.categories.toString(), plan.preview.hasChanges)
        assertEquals(emptyList<String>(), plan.preview.notices)
        val counts = plan.preview.categories.associateBy { it.category }
        assertEquals(2, counts.getValue(TransferCategory.History).unchanged)
        assertEquals(1, counts.getValue(TransferCategory.Recordings).unchanged)
    }

    @Test
    fun credentials_areExportedOnlyWhenChosen() {
        val withoutKeys = export(includeCredentials = false)
        assertNull(withoutKeys.records[TransferCategory.Credentials])
        assertFalse(TransferCategory.Credentials in withoutKeys.manifest.categories)

        val withKeys = export(includeCredentials = true)
        assertEquals(setOf(openAi, groq), withKeys.records.getValue(TransferCategory.Credentials).map { it.id }.toSet())
    }

    @Test
    fun credentials_areImportedOnlyWhenChosen() = runBlocking {
        val prefs = MemoryPrefs()
        val secrets = MemorySecrets(openAi to "sk-mine")
        val store = HistoryStore(MemoryHistoryFile())
        val plan = ConfigImporter.plan(export(includeCredentials = true), prefs, emptyList(), secrets.names(), nowMs)

        assertTrue(applier(prefs, secrets, store).applyPlan(plan, includeCredentials = false))

        assertEquals("sk-mine", secrets.read(openAi))
        assertNull(secrets.read(groq))
        assertEquals("Keep it short.", prefs.cleanupPrompt)
    }

    @Test
    fun corruptArchive_isRejectedBeforeAnythingChanges() {
        val valid = folder.newFile().apply { outputStream().use { ConfigExporter.export(it, sourcePrefs(), sourceHistory(), MemorySecrets(), false, nowMs) } }
        val corrupt = folder.newFile().apply { writeBytes(valid.readBytes().copyOf(valid.length().toInt() / 2)) }
        try {
            ConfigArchiveReader.read(corrupt, folder.newFolder())
            fail("A truncated archive should not be readable")
        } catch (_: ConfigArchiveException) {
        }
    }

    @Test
    fun failedHistoryWrite_leavesEverythingAsItWas() = runBlocking {
        val prefs = MemoryPrefs()
        val before = prefs.copyValues()
        val secrets = MemorySecrets(openAi to "sk-mine")
        val plan = ConfigImporter.plan(export(includeCredentials = true), prefs, emptyList(), secrets.names(), nowMs)
        val recordings = File(folder.root, "recordings")
        val applier = ConfigImportApplier(prefs, secrets, recordings, Dispatchers.Unconfined) { _, _ -> throw IOException("disk full") }

        assertFalse(applier.applyPlan(plan, includeCredentials = true))

        assertEquals(before, prefs.copyValues())
        assertEquals(setOf(openAi), secrets.names())
        assertEquals("sk-mine", secrets.read(openAi))
        assertTrue(recordings.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun failedKeyWrite_leavesEverythingAsItWas() = runBlocking {
        val prefs = MemoryPrefs()
        val before = prefs.copyValues()
        val memory = MemorySecrets(openAi to "sk-mine")
        // OpenAI's key is written before Groq's fails, so it must be restored.
        val secrets = object : SecretStore by memory {
            override fun write(name: String, value: String) {
                if (name == groq) throw GeneralSecurityException("keystore locked")
                memory.write(name, value)
            }
        }
        val store = HistoryStore(MemoryHistoryFile())
        val plan = ConfigImporter.plan(export(includeCredentials = true), prefs, emptyList(), setOf(openAi), nowMs)

        assertFalse(applier(prefs, secrets, store).applyPlan(plan, includeCredentials = true))

        assertEquals(before, prefs.copyValues())
        assertEquals("sk-mine", memory.read(openAi))
        assertNull(memory.read(groq))
        assertEquals(emptyList<HistoryEntry>(), store.load(Retention.Forever))
    }

    @Test
    fun unknownKeysAndUnsupportedValues_areSkippedWithANotice() {
        val archive = folder.newFile()
        val records = mapOf(
            TransferCategory.Settings to listOf(
                ArchiveRecord(id = "hotKeyActivationStyle", kind = RecordKinds.SETTING, value = "doubleTap"),
                ArchiveRecord(id = SharedSettings.LANGUAGE, kind = RecordKinds.SETTING, value = "xx_NOPE"),
                ArchiveRecord(id = SharedSettings.KEEP_AUDIO, kind = RecordKinds.SETTING, value = false),
            ),
        )
        archive.outputStream().use {
            ConfigArchiveWriter.write(it, ArchiveManifest(ArchiveFormat.VERSION, nowMs, listOf(TransferCategory.Settings)), records)
        }
        val prefs = MemoryPrefs(keepAudioOnCancel = true, languageId = "en_US")
        val plan = ConfigImporter.plan(ConfigArchiveReader.read(archive, folder.newFolder()), prefs, emptyList(), emptySet(), nowMs)

        val settings = plan.preview.categories.single { it.category == TransferCategory.Settings }
        assertEquals(1, settings.updated)
        assertEquals(2, settings.skipped)
        assertEquals(2, plan.preview.notices.size)
        assertEquals(false, plan.settings.keepAudioOnCancel)
        assertNull(plan.settings.languageId)
    }

    private fun MemoryPrefs.copyValues(): List<Any?> = listOf(
        chosenMode, cloudModelId, cleanupModelId, cleanupEnabled, retention, keepAudioOnCancel, languageId,
        corrections, cleanupPrompt, profiles, activeProfileId,
    )

    private companion object {
        const val FIRST = "6f1c2a52-3b6e-4d7e-9a43-2f6a1b0c9d11"
        const val SECOND = "0b9e7c44-8d2f-4a15-b6e3-7c1d2e3f4a55"
        val PROFILE = DictationProfile(
            id = "2C4B6A10-9E8D-4F7C-A1B2-3C4D5E6F7A8B",
            name = "Meetings",
            languageId = "en_GB",
            cleanupEnabled = true,
            cleanupPrompt = "Bullet points.",
        )
    }
}
