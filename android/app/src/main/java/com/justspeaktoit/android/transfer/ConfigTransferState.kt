package com.justspeaktoit.android.transfer

import android.annotation.SuppressLint
import java.io.File
import java.io.IOException
import java.io.InputStream

/** How the last export or import ended, shown under the Export and import card. */
enum class TransferOutcome { Exported, ExportFailed, Imported, ImportFailed, Unreadable }

data class ConfigTransferState(
    /** Opt-in for the next export: API keys are written unencrypted, so it is never on by default. */
    val exportCredentials: Boolean = false,
    val busy: Boolean = false,
    /** The import waiting for the user to apply or cancel it. */
    val preview: ImportPreview? = null,
    /** Opt-in for applying [preview]'s API keys; reset for every file. */
    val importCredentials: Boolean = false,
    val outcome: TransferOutcome? = null,
    /** Why a file could not be read, in the shared wording. */
    val detail: String? = null,
    /** Changes after each import, so fields that keep their own text reload the saved value. */
    val generation: Int = 0,
)

/**
 * The private copy of a chosen archive and its staged recordings. Callers run one operation at a
 * time, on one thread, so a dismissal never deletes the files of a newer import.
 */
internal class ConfigTransferFiles(private val dir: File) {
    /**
     * Copies the archive [open] returns and reads it, staging its recordings. Throws
     * [ConfigArchiveException] when it is not a readable export, and IOException when it cannot be
     * copied; either way nothing is left behind.
     */
    fun read(open: () -> InputStream?): ArchiveContents {
        clear()
        val archive = File(dir, "import.zip")
        var ok = false
        try {
            if (!dir.mkdirs() && !dir.isDirectory) throw IOException("Cannot create ${dir.name}")
            val input = open() ?: throw IOException("The file could not be opened.")
            input.use { copy(it, archive) }
            return ConfigArchiveReader.read(archive, File(dir, "staged")).also { ok = true }
        } finally {
            archive.delete()
            if (!ok) clear()
        }
    }

    fun clear() {
        dir.deleteRecursively()
    }

    /** Stops before the copy could fill the phone, leaving room to stage the recordings. */
    // getAllocatableBytes counts cache the system frees only through allocateBytes, which a
    // plain stream copy cannot use, so usableSpace is the space this write can really fill.
    @SuppressLint("UsableSpace")
    private fun copy(input: InputStream, target: File) {
        val limit = minOf(ArchiveFormat.MAX_ARCHIVE_BYTES, dir.usableSpace - ArchiveFormat.STAGING_RESERVE_BYTES)
        val buffer = ByteArray(COPY_BUFFER_BYTES)
        var total = 0L
        target.outputStream().use { output ->
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > limit) throw ConfigArchiveException(NO_SPACE)
                output.write(buffer, 0, read)
            }
        }
    }

    private companion object {
        const val COPY_BUFFER_BYTES = 64 * 1024
        const val NO_SPACE = "There is not enough free space on this phone to read this export."
    }
}
