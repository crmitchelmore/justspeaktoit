package com.justspeaktoit.android.transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Reads the archives SpeakCore's own tests use (`Tests/SpeakTestSupport/MigrationArchiveFixtures`),
 * so Android keeps reading exactly what the Mac and iPhone write and rejects what they reject.
 */
class ConfigArchiveFixturesTest {
    @get:Rule val folder = TemporaryFolder()

    private fun read(name: String): ArchiveContents = ConfigArchiveReader.read(fixture(name), folder.newFolder())

    @Test
    fun validArchives_readSettingsAndTheirRecording() {
        listOf("stored", "deflate", "zip64", "long-unicode").forEach { name ->
            val contents = read(name)
            assertEquals(name, 1, contents.records[TransferCategory.Settings]?.size)
            assertEquals(name, 1, contents.records[TransferCategory.Recordings]?.size)
            assertEquals(name, 1, contents.files.size)
            assertTrue(name, contents.files.values.all { it.isFile })
            assertEquals(name, emptyList<String>(), contents.notices)
        }
    }

    @Test
    fun damagedRecording_isSkippedWithANotice() {
        listOf("bad-audio-crc", "bad-digest").forEach { name ->
            val contents = read(name)
            assertEquals(name, emptyList<ArchiveRecord>(), contents.records[TransferCategory.Recordings].orEmpty())
            assertEquals(name, 1, contents.notices.size)
            assertTrue(name, contents.files.isEmpty())
        }
    }

    @Test
    fun damagedOrAmbiguousArchives_areRejected() {
        listOf("bad-manifest-crc", "duplicate-path").forEach { name ->
            try {
                read(name)
                fail("$name should not be readable")
            } catch (_: ConfigArchiveException) {
            }
        }
    }

    @Test
    fun missingCategory_isReportedAndPreservesExistingData() {
        val contents = read("missing-category")
        assertEquals(null, contents.records[TransferCategory.Settings])
        assertEquals(
            listOf("Settings & shortcuts: category could not be read; existing data will be preserved."),
            contents.notices,
        )
    }

    @Test
    fun invalidOrDuplicateItems_keepTheValidRecording() {
        listOf("invalid-item", "duplicate-recording").forEach { name ->
            val contents = read(name)
            assertEquals(name, 1, contents.records[TransferCategory.Recordings]?.size)
            assertEquals(name, 1, contents.notices.size)
        }
    }

    @Test
    fun traversalAndSymlinks_areReportedWithoutStagingAnything() {
        listOf("traversal", "symlink").forEach { name ->
            val staging = folder.newFolder()
            val contents = ConfigArchiveReader.read(fixture(name), staging)
            assertEquals(name, emptyList<ArchiveRecord>(), contents.records[TransferCategory.Recordings])
            assertEquals(name, 1, contents.records[TransferCategory.Settings]?.size)
            assertEquals(name, 1, contents.notices.size)
            assertTrue(name, contents.files.isEmpty())
            assertTrue(name, staging.listFiles().orEmpty().isEmpty())
        }
    }

    private fun fixture(name: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "Tests/SpeakTestSupport/MigrationArchiveFixtures/$name.zip")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        error("Migration fixture $name.zip not found above ${File("").absolutePath}")
    }
}
