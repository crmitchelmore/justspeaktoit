package com.justspeaktoit.android.cloud

import java.io.File

/** Locates the shared Swift sources so parity tests compare against the Mac app's definitions. */
object RepoSources {
    fun speakCore(fileName: String): String {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "Sources/SpeakCore/$fileName")
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        error("Sources/SpeakCore/$fileName not found above ${File("").absolutePath}")
    }
}
