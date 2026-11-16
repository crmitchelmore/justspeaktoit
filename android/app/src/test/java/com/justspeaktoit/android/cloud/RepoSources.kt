package com.justspeaktoit.android.cloud

import java.io.File

/** Locates the shared Swift sources so parity tests compare against the Mac app's definitions. */
object RepoSources {
    fun speakCore(fileName: String): String = read("Sources/SpeakCore/$fileName")

    /** A fixture shared with the Swift tests, for example `openrouter-browser/filter-cases.json`. */
    fun fixture(path: String): String = read("Tests/Fixtures/$path")

    private fun read(path: String): String {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, path)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        error("$path not found above ${File("").absolutePath}")
    }
}
