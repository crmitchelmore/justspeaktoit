package com.justspeaktoit.android.transfer

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/** A recording to export, measured in one pass so the archive entry and its record agree. */
internal data class ArchiveAudio(val file: File, val size: Long, val crc: Long, val sha256: String) {
    companion object {
        fun measure(file: File): ArchiveAudio {
            val crc = CRC32()
            val digest = MessageDigest.getInstance("SHA-256")
            var size = 0L
            FileInputStream(file).use { input ->
                val buffer = ByteArray(BUFFER_BYTES)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    crc.update(buffer, 0, read)
                    digest.update(buffer, 0, read)
                    size += read
                }
            }
            return ArchiveAudio(file, size, crc.value, digest.digest().hex())
        }
    }
}

private const val BUFFER_BYTES = 64 * 1024

/**
 * Writes the shared archive. Every entry is STORED with its size and CRC known up front, so no entry
 * needs a data descriptor and every reader (SpeakCore's included) can stream it.
 */
internal object ConfigArchiveWriter {
    fun write(
        output: OutputStream,
        manifest: ArchiveManifest,
        records: Map<TransferCategory, List<ArchiveRecord>>,
        audio: Map<String, ArchiveAudio> = emptyMap(),
        extras: Map<String, ByteArray> = emptyMap(),
    ) {
        ZipOutputStream(BufferedOutputStream(output)).use { zip ->
            zip.putBytes(ArchiveFormat.MANIFEST, manifest.toJson().toString().toByteArray(Charsets.UTF_8))
            manifest.categories.forEach { category ->
                val items = JSONArray(records[category].orEmpty().map(ArchiveRecord::toJson))
                zip.putBytes(ArchiveFormat.categoryEntry(category), items.toString().toByteArray(Charsets.UTF_8))
            }
            extras.forEach { (name, bytes) -> zip.putBytes(name, bytes) }
            audio.forEach { (path, item) -> zip.putFile(path, item) }
        }
    }

    private fun ZipOutputStream.putBytes(name: String, bytes: ByteArray) {
        val crc = CRC32().apply { update(bytes) }
        putNextEntry(stored(name, bytes.size.toLong(), crc.value))
        write(bytes)
        closeEntry()
    }

    /** A recording that changed after it was measured fails the export rather than writing a bad entry. */
    private fun ZipOutputStream.putFile(name: String, audio: ArchiveAudio) {
        putNextEntry(stored(name, audio.size, audio.crc))
        FileInputStream(audio.file).use { it.copyTo(this, BUFFER_BYTES) }
        closeEntry()
    }

    private fun stored(name: String, size: Long, crc: Long) = ZipEntry(name).apply {
        method = ZipEntry.STORED
        this.size = size
        compressedSize = size
        this.crc = crc
    }
}

/**
 * Reads the shared archive as `DesktopMigrationArchive` does. The manifest must be intact; a category
 * that cannot be read is left out (so its existing data is kept) and an item that cannot be read is
 * skipped, each with the shared notice. Archive names never become destinations: only declared audio
 * is copied, to new private files, after its size, CRC and SHA-256 are checked.
 */
internal object ConfigArchiveReader {
    private const val UNREADABLE = "This file is not a readable export."

    fun read(archive: File, staging: File, availableBytes: (File) -> Long = File::getUsableSpace): ArchiveContents {
        val zip = try {
            ZipFile(archive)
        } catch (e: IOException) {
            throw ConfigArchiveException(UNREADABLE, e)
        }
        return zip.use {
            val irregular = try {
                ZipEntryModes.irregular(archive)
            } catch (e: IOException) {
                throw ConfigArchiveException(UNREADABLE, e)
            }
            read(Source(it, irregular), staging, availableBytes)
        }
    }

    /** The open archive and the entries that are not regular files, which are never read. */
    private class Source(val zip: ZipFile, val irregular: Set<String>) {
        fun regular(name: String): ZipEntry? = zip.getEntry(name)?.takeIf { it.name !in irregular }
    }

    private fun read(source: Source, staging: File, availableBytes: (File) -> Long): ArchiveContents {
        val zip = source.zip
        val total = preflight(zip)
        if (!staging.isDirectory && !staging.mkdirs()) throw ConfigArchiveException("Could not prepare the import.")
        val available = availableBytes(staging)
        if (available > 0 && total + ArchiveFormat.STAGING_RESERVE_BYTES > available) {
            throw ConfigArchiveException("There is not enough free space to read this export.")
        }
        val manifestEntry = source.regular(ArchiveFormat.MANIFEST) ?: throw ConfigArchiveException("No migration manifest found.")
        val manifestBytes = try {
            readEntry(zip, manifestEntry, ArchiveFormat.MAX_JSON_BYTES)
        } catch (e: IOException) {
            throw ConfigArchiveException("The export manifest is damaged.", e)
        }
        val manifest = ArchiveManifest.parse(String(manifestBytes, Charsets.UTF_8))
        val staged = mutableMapOf<String, File>()
        try {
            val notices = mutableListOf<String>()
            val records = mutableMapOf<TransferCategory, List<ArchiveRecord>>()
            manifest.categories.forEach { category ->
                readCategory(source, category, staging, staged, notices)?.let { records[category] = it }
            }
            val androidSettings = if (TransferCategory.Settings in manifest.categories) androidSettings(source) else null
            return ArchiveContents(manifest, records, staged.toMap(), notices, androidSettings)
        } catch (e: Throwable) {
            staged.values.forEach(File::delete)
            throw e
        }
    }

    /** `DataMigrationArchivePolicy.preflight`: duplicate paths or oversized entries reject the archive. */
    private fun preflight(zip: ZipFile): Long {
        val names = mutableSetOf<String>()
        var total = 0L
        try {
            for (entry in zip.entries()) {
                if (names.size >= ArchiveFormat.MAX_ENTRIES || !names.add(entry.name) ||
                    entry.size < 0 || entry.size > ArchiveFormat.MAX_ENTRY_BYTES
                ) {
                    throw ConfigArchiveException("The archive contains duplicate paths or oversized entries.")
                }
                total += entry.size
                if (total > ArchiveFormat.MAX_ARCHIVE_BYTES) throw ConfigArchiveException("The archive exceeds 50 GB.")
            }
        } catch (e: IllegalStateException) {
            throw ConfigArchiveException(UNREADABLE, e)
        }
        return total
    }

    private fun readCategory(
        source: Source,
        category: TransferCategory,
        staging: File,
        staged: MutableMap<String, File>,
        notices: MutableList<String>,
    ): List<ArchiveRecord>? {
        val values = try {
            val entry = source.regular(ArchiveFormat.categoryEntry(category)) ?: throw IOException("Category file missing.")
            JSONArray(String(readEntry(source.zip, entry, ArchiveFormat.MAX_JSON_BYTES), Charsets.UTF_8))
        } catch (e: IOException) {
            notices += "${category.title}: category could not be read; existing data will be preserved."
            return null
        } catch (e: JSONException) {
            notices += "${category.title}: category could not be read; existing data will be preserved."
            return null
        }
        val records = mutableListOf<ArchiveRecord>()
        val seen = mutableSetOf<String>()
        for (index in 0 until values.length()) {
            val record = ArchiveRecord.parse(values.opt(index))
            if (record != null && seen.add(record.identity) &&
                (category != TransferCategory.Recordings || stage(source, record, staging, staged))
            ) {
                records += record
            } else {
                notices += "${category.title}, item ${index + 1}: skipped invalid item."
            }
        }
        return records
    }

    /** Copies a recording's declared audio to private staging; false when it is missing or damaged. */
    private fun stage(source: Source, record: ArchiveRecord, staging: File, staged: MutableMap<String, File>): Boolean {
        val path = record.file ?: return false
        if (!ArchiveFormat.safeAudioPath(path) || path in staged) return false
        val entry = source.regular(path) ?: return false
        val target = File(staging, "${UUID.randomUUID()}.${ArchiveFormat.extension(path)}")
        val output = try {
            FileOutputStream(target)
        } catch (e: IOException) {
            throw ConfigArchiveException("Could not stage the import's recordings.", e)
        }
        val ok = try {
            output.use { copyVerified(source.zip, entry, it) == record.digest }
        } catch (e: StagingWriteFailure) {
            target.delete()
            throw ConfigArchiveException("Could not stage the import's recordings.", e.cause)
        } catch (e: IOException) {
            false
        } catch (e: RuntimeException) {
            target.delete()
            throw e
        }
        if (ok) staged[path] = target else target.delete()
        return ok
    }

    /** The SHA-256 of the entry, or null when its size or CRC does not match the archive's record of it. */
    private fun copyVerified(zip: ZipFile, entry: ZipEntry, output: OutputStream): String? {
        val crc = CRC32()
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        zip.getInputStream(entry).use { input ->
            val buffer = ByteArray(BUFFER_BYTES)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                size += read
                if (size > entry.size) return null
                crc.update(buffer, 0, read)
                digest.update(buffer, 0, read)
                try {
                    output.write(buffer, 0, read)
                } catch (e: IOException) {
                    throw StagingWriteFailure(e)
                }
            }
        }
        if (size != entry.size || (entry.crc != -1L && crc.value != entry.crc)) return null
        return digest.digest().hex()
    }

    /** Java's ZipFile does not check CRCs, so every entry read is checked here. */
    private fun readEntry(zip: ZipFile, entry: ZipEntry, limit: Long): ByteArray {
        if (entry.size < 0 || entry.size > limit) throw IOException("Entry too large.")
        val bytes = zip.getInputStream(entry).use { it.readCapped(entry.size) }
        val crc = CRC32().apply { update(bytes) }
        if (bytes.size.toLong() != entry.size || (entry.crc != -1L && crc.value != entry.crc)) {
            throw IOException("Entry damaged.")
        }
        return bytes
    }

    private fun InputStream.readCapped(expected: Long): ByteArray {
        val bytes = ByteArray(expected.toInt())
        var offset = 0
        while (offset < bytes.size) {
            val read = read(bytes, offset, bytes.size - offset)
            if (read < 0) break
            offset += read
        }
        // A short read or extra bytes mean the entry is not what the directory says.
        if (offset != bytes.size || read() >= 0) throw IOException("Entry damaged.")
        return bytes
    }

    /** Only an Android export has this; an unreadable one is ignored like any unknown entry. */
    private fun androidSettings(source: Source): JSONObject? {
        val entry = source.regular(ArchiveFormat.ANDROID_SETTINGS) ?: return null
        return try {
            JSONObject(String(readEntry(source.zip, entry, ArchiveFormat.MAX_JSON_BYTES), Charsets.UTF_8))
        } catch (e: IOException) {
            null
        } catch (e: JSONException) {
            null
        }
    }

    private class StagingWriteFailure(cause: IOException) : Exception(cause)
}

/**
 * Finds entries whose Unix mode marks them as something other than a regular file, such as a
 * symbolic link. Java's ZipFile does not expose the mode, so this reads the central directory, as
 * SpeakCore's readers check each entry is a regular file before using it.
 */
internal object ZipEntryModes {
    private const val END = 0x06054b50
    private const val ZIP64_LOCATOR = 0x07064b50
    private const val ZIP64_END = 0x06064b50
    private const val CENTRAL = 0x02014b50
    private const val END_BYTES = 22
    private const val LOCATOR_BYTES = 20
    private const val MAX_COMMENT_BYTES = 0xFFFF
    private const val CENTRAL_BYTES = 46
    private const val UNIX_HOST = 3
    private const val TYPE_MASK = 0xF000
    private const val REGULAR = 0x8000
    private const val UNSET_16 = 0xFFFF
    private const val UNSET_32 = 0xFFFFFFFFL

    fun irregular(archive: File): Set<String> = RandomAccessFile(archive, "r").use { file ->
        val (offset, size) = directory(file)
        if (size > ArchiveFormat.MAX_JSON_BYTES || offset + size > file.length()) throw IOException("Bad central directory.")
        val bytes = ByteArray(size.toInt())
        file.seek(offset)
        file.readFully(bytes)
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val names = mutableSetOf<String>()
        while (buffer.remaining() >= CENTRAL_BYTES) {
            val start = buffer.position()
            if (buffer.getInt(start) != CENTRAL) break
            val host = buffer.get(start + 5).toInt() and 0xFF
            val nameLength = buffer.getShort(start + 28).toInt() and 0xFFFF
            val extraLength = buffer.getShort(start + 30).toInt() and 0xFFFF
            val commentLength = buffer.getShort(start + 32).toInt() and 0xFFFF
            val mode = buffer.getInt(start + 38) ushr 16
            val end = start + CENTRAL_BYTES + nameLength + extraLength + commentLength
            if (end > bytes.size) throw IOException("Bad central directory.")
            val type = mode and TYPE_MASK
            if (host == UNIX_HOST && type != 0 && type != REGULAR) {
                names += String(bytes, start + CENTRAL_BYTES, nameLength, Charsets.UTF_8)
            }
            buffer.position(end)
        }
        names
    }

    /** The central directory's offset and size, from the (ZIP64) end of central directory record. */
    private fun directory(file: RandomAccessFile): Pair<Long, Long> {
        val tailLength = minOf(file.length(), (END_BYTES + MAX_COMMENT_BYTES).toLong()).toInt()
        val tailStart = file.length() - tailLength
        val tail = ByteArray(tailLength)
        file.seek(tailStart)
        file.readFully(tail)
        val buffer = ByteBuffer.wrap(tail).order(ByteOrder.LITTLE_ENDIAN)
        val end = (tailLength - END_BYTES downTo 0).firstOrNull { buffer.getInt(it) == END }
            ?: throw IOException("No end of central directory.")
        val count = buffer.getShort(end + 10).toInt() and 0xFFFF
        val size = buffer.getInt(end + 12).toLong() and UNSET_32
        val offset = buffer.getInt(end + 16).toLong() and UNSET_32
        if (count != UNSET_16 && size != UNSET_32 && offset != UNSET_32) return offset to size
        val locator = end - LOCATOR_BYTES
        if (locator < 0 || buffer.getInt(locator) != ZIP64_LOCATOR) throw IOException("No ZIP64 locator.")
        val record = ByteArray(56)
        file.seek(buffer.getLong(locator + 8))
        file.readFully(record)
        val zip64 = ByteBuffer.wrap(record).order(ByteOrder.LITTLE_ENDIAN)
        if (zip64.getInt(0) != ZIP64_END) throw IOException("No ZIP64 end of central directory.")
        return zip64.getLong(48) to zip64.getLong(40)
    }
}
