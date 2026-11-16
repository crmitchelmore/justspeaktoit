package com.justspeaktoit.android.sync

/**
 * CloudKit Web Services settings for History sync: the Mac container that Windows and Linux already
 * share (Docs/windows-cloudkit-sync.md), so a user's Mac History appears on Android too.
 *
 * The API token belongs to the developer's container and is created in CloudKit Console. A build
 * receives it at build time (the `CLOUDKIT_WEB_API_TOKEN` CI secret, read by app/build.gradle.kts
 * into BuildConfig, as the desktop builds do). Without one, sync is unavailable and says why; every
 * other feature keeps working.
 */
data class CloudKitConfig(val container: String, val environment: String, val apiToken: String) {
    companion object {
        const val DEFAULT_CONTAINER = "iCloud.com.justspeaktoit"
        const val DEFAULT_ENVIRONMENT = "production"
        const val BASE_URL = "https://api.apple-cloudkit.com"
        private val environments = setOf("development", "production")
        private val containerPattern = Regex("iCloud\\.[A-Za-z0-9.-]+")

        fun resolve(token: String, environment: String, container: String): CloudKitResolution {
            val apiToken = token.trim()
            if (apiToken.isEmpty()) return CloudKitResolution.Unavailable(CloudKitUnavailable.MissingToken)
            val env = environment.trim().ifEmpty { DEFAULT_ENVIRONMENT }
            val box = container.trim().ifEmpty { DEFAULT_CONTAINER }
            if (env !in environments || !containerPattern.matches(box)) {
                return CloudKitResolution.Unavailable(CloudKitUnavailable.Misconfigured)
            }
            return CloudKitResolution.Available(CloudKitConfig(box, env, apiToken))
        }
    }
}

/** Why History sync cannot run in this build. */
enum class CloudKitUnavailable { MissingToken, Misconfigured }

sealed interface CloudKitResolution {
    data class Available(val config: CloudKitConfig) : CloudKitResolution

    data class Unavailable(val reason: CloudKitUnavailable) : CloudKitResolution
}
