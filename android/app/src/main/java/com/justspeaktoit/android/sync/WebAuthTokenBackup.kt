package com.justspeaktoit.android.sync

import java.io.File
import java.io.IOException

/**
 * Where the CloudKit web auth token waits for Android Auto Backup and device-to-device transfer to carry
 * it to a new phone. The Keystore key that encrypts the live copy cannot leave the device, so this copy
 * lives in one file that `data_extraction_rules.xml` includes only in an end-to-end encrypted cloud
 * backup or a direct device transfer.
 */
interface WebAuthTokenBackup {
    fun read(): String?

    fun write(token: String)

    fun delete()
}

internal class FileWebAuthTokenBackup(private val file: File) : WebAuthTokenBackup {
    override fun read(): String? = try {
        file.takeIf { it.isFile }?.readText(Charsets.UTF_8)?.takeIf { it.isNotEmpty() }
    } catch (e: IOException) {
        null
    }

    override fun write(token: String) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeText(token, Charsets.UTF_8)
        if (!temp.renameTo(file)) {
            temp.delete()
            throw IOException("Could not replace the token backup.")
        }
    }

    override fun delete() {
        if (file.exists() && !file.delete()) throw IOException("Could not delete the token backup.")
    }
}

/** Mirrors every saved token into [backup] and removes the mirror on sign-out or when the token is rejected. */
class BackupMirroringTokenStore(
    private val live: WebAuthTokenStore,
    private val backup: WebAuthTokenBackup,
) : WebAuthTokenStore {
    override fun load(): String? = live.load()

    override fun save(token: String) {
        live.save(token)
        // The live copy is the source of truth; a failed mirror only costs the automatic restore.
        try {
            backup.write(token)
        } catch (e: IOException) {
            return
        }
    }

    override fun clear() {
        live.clear()
        backup.delete()
    }
}
