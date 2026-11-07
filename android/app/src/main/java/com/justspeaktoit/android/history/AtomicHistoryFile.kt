package com.justspeaktoit.android.history

import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException

/** Crash-safe replacement: a write is either fully visible or not at all. */
class AtomicHistoryFile(file: File) : HistoryFile {
    private val atomic = AtomicFile(file)

    override fun read(): String? = try {
        atomic.readFully().toString(Charsets.UTF_8)
    } catch (e: FileNotFoundException) {
        null
    }

    override fun write(text: String) {
        val out = atomic.startWrite()
        try {
            out.write(text.toByteArray())
            atomic.finishWrite(out)
        } catch (e: java.io.IOException) {
            atomic.failWrite(out)
            throw e
        }
    }

    override fun delete() = atomic.delete()
}
