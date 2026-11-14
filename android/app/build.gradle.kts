import groovy.json.JsonSlurper

// Play upload signing. CI decodes the upload keystore from the main-only `android-release`
// environment (Docs/android-play-store-submission.md); without it the release bundle is unsigned.
val uploadKeystore = providers.environmentVariable("JSTI_ANDROID_KEYSTORE_PATH").orNull
// Play rejects a version code it has seen, so CI supplies a monotonically increasing one.
val ciVersionCode = providers.environmentVariable("JSTI_ANDROID_VERSION_CODE").orNull?.toInt()
// PostHog's public project key, from the POSTHOG_PROJECT_KEY secret in the release workflows. Without
// it (local and PR builds) product analytics has no destination and never opens a connection.
val postHogProjectKey = providers.environmentVariable("POSTHOG_PROJECT_KEY").orNull?.trim()
    ?.takeIf { Regex("[A-Za-z0-9_]+").matches(it) }
    .orEmpty()
// CloudKit Web Services API token for History sync, from the CLOUDKIT_WEB_API_TOKEN secret that the
// Windows and Linux builds use too (Docs/windows-cloudkit-sync.md). Without it the build reports that
// iCloud sync is unavailable. JSTI_CLOUDKIT_WEB_ENVIRONMENT selects development for testing.
val cloudKitWebApiToken = providers.environmentVariable("CLOUDKIT_WEB_API_TOKEN").orNull?.trim()
    ?.takeIf { Regex("[A-Za-z0-9_-]+").matches(it) }
    .orEmpty()
val cloudKitWebEnvironment = providers.environmentVariable("JSTI_CLOUDKIT_WEB_ENVIRONMENT").orNull?.trim()
    ?.takeIf { it == "development" || it == "production" }
    ?: "production"

plugins {
    // AGP 9 compiles Kotlin itself, so the separate Kotlin Android plugin is no longer applied.
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.justspeaktoit.android"
    // AndroidX 1.19 core and Compose 1.12 require compiling against API 37.
    compileSdk = 37

    defaultConfig {
        applicationId = "com.justspeaktoit.android"
        minSdk = 29
        targetSdk = 36
        versionCode = ciVersionCode ?: 1
        versionName = "0.1.0"
        buildConfigField("String", "POSTHOG_PROJECT_KEY", "\"$postHogProjectKey\"")
        buildConfigField("String", "CLOUDKIT_WEB_API_TOKEN", "\"$cloudKitWebApiToken\"")
        buildConfigField("String", "CLOUDKIT_WEB_ENVIRONMENT", "\"$cloudKitWebEnvironment\"")
    }

    signingConfigs {
        if (uploadKeystore != null) {
            create("upload") {
                storeFile = file(uploadKeystore)
                storePassword = providers.environmentVariable("JSTI_ANDROID_KEYSTORE_PASSWORD").get()
                keyAlias = providers.environmentVariable("JSTI_ANDROID_KEY_ALIAS").get()
                keyPassword = providers.environmentVariable("JSTI_ANDROID_KEY_PASSWORD").get()
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (uploadKeystore != null) signingConfig = signingConfigs.getByName("upload")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    lint {
        warningsAsErrors = true
        // Zero warnings. These checks only report that something newer was published upstream, so they
        // would fail an unchanged tree; Dependabot (gradle) and the Play target-SDK policy own currency.
        disable += setOf("GradleDependency", "AndroidGradlePluginVersion", "NewerVersionAvailable", "OldTargetApi")
        abortOnError = true
        checkDependencies = true
        // Accessibility regressions fail CI (Docs/accessibility.md).
        error += setOf("ContentDescription", "KeyboardInaccessibleWidget", "LabelFor", "ClickableViewAccessibility")
    }

}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.android.billing)
    implementation(libs.androidx.fragment)
    implementation(libs.sentry.android.core)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.org.json)
}

/**
 * Writes `GeneratedCloudCatalog.kt` from `assets/cloud_catalog.json`, which SpeakCore's
 * `CloudCatalogAndroidExport` generates. The Kotlin constants are therefore never hand-edited, and
 * stay compile-time values so the catalogue costs nothing at startup.
 */
abstract class GenerateCloudCatalog : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val catalog: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun generate() {
        @Suppress("UNCHECKED_CAST")
        val json = JsonSlurper().parse(catalog.get().asFile, "UTF-8") as Map<String, Any?>
        val version = json["version"] as Int
        check(version == 1) { "cloud_catalog.json version $version is not understood; update this generator" }
        fun lit(value: Any?): String = "\"" + value.toString()
            .replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$")
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "\""
        fun optLit(value: Any?): String = if (value == null) "null" else lit(value)
        fun optInt(value: Any?): String = (value as Number?)?.toInt()?.toString() ?: "null"
        @Suppress("UNCHECKED_CAST")
        fun strings(value: Any?): String = (value as List<Any?>).joinToString(", ", "listOf(", ")") { lit(it) }
        @Suppress("UNCHECKED_CAST")
        fun objects(key: String) = json[key] as List<Map<String, Any?>>
        @Suppress("UNCHECKED_CAST")
        val cleanup = json["cleanup"] as Map<String, Any?>
        val providers = objects("providers").joinToString("") {
            "        CloudProviderSpec(id = ${lit(it["id"])}, credentialId = ${lit(it["credentialId"])}),\n"
        }
        @Suppress("UNCHECKED_CAST")
        fun codes(value: Any?): String = (value as List<Any?>?)
            ?.joinToString(", ", prefix = "listOf(", postfix = ")") { lit(it) } ?: "null"
        val models = objects("transcriptionModels").joinToString("") {
            "        CloudModelSpec(\n" +
                "            catalogId = ${lit(it["catalogId"])},\n" +
                "            displayName = ${lit(it["displayName"])},\n" +
                "            providerId = ${lit(it["provider"])},\n" +
                "            apiName = ${lit(it["apiName"])},\n" +
                "            languageField = ${lit(it["languageField"])},\n" +
                "            supportsPrompt = ${it["supportsPrompt"] as Boolean},\n" +
                "            languageCodes = ${codes(it["languageCodes"])},\n" +
                "        ),\n"
        }
        val cleanupModels = objects("cleanupModels").joinToString("") {
            "        CleanupModelSpec(\n" +
                "            selectionId = ${lit(it["selectionId"])},\n" +
                "            displayName = ${lit(it["displayName"])},\n" +
                "            providerId = ${lit(it["provider"])},\n" +
                "            apiName = ${lit(it["apiName"])},\n" +
                "        ),\n"
        }
        val languages = objects("languages").joinToString("") {
            "        TranscriptionLanguageSpec(id = ${lit(it["id"])}, displayName = ${lit(it["displayName"])}),\n"
        }
        @Suppress("UNCHECKED_CAST")
        val keywordPrompt = json["keywordPrompt"] as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        val successors = (json["cleanupModelSuccessors"] as Map<String, Any?>? ?: emptyMap())
            .toSortedMap().entries.joinToString("") {
                "        ${lit(it.key)} to ${lit(it.value)},\n"
            }
        @Suppress("UNCHECKED_CAST")
        val browser = json["openRouterBrowser"] as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        val browserModels = (browser["cleanupModels"] as List<Map<String, Any?>>).joinToString("") {
            "        OpenRouterBrowserModelSpec(\n" +
                "            selectionId = ${lit(it["selectionId"])},\n" +
                "            slug = ${lit(it["slug"])},\n" +
                "            name = ${lit(it["name"])},\n" +
                "            provider = ${lit(it["provider"])},\n" +
                "            subtitle = ${lit(it["subtitle"])},\n" +
                "            summary = ${lit(it["summary"])},\n" +
                "            speed = ${lit(it["speed"])},\n" +
                "            pricing = ${optLit(it["pricing"])},\n" +
                "            contextLength = ${optInt(it["contextLength"])},\n" +
                "            strengths = ${strings(it["strengths"])},\n" +
                "            hasZeroPrices = ${it["hasZeroPrices"] as Boolean},\n" +
                "            searchText = ${strings(it["searchText"])},\n" +
                "            modelPageUrl = ${optLit(it["modelPageURL"])},\n" +
                "        ),\n"
        }
        @Suppress("UNCHECKED_CAST")
        val profiles = json["profiles"] as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        val voiceEdit = json["voiceEdit"] as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        val profileFields = (profiles["fields"] as List<Any?>).joinToString("") { "        ${lit(it)},\n" }
        val source = """
            |// Generated by :app:generateCloudCatalog from src/main/assets/cloud_catalog.json. Do not edit.
            |package com.justspeaktoit.android.cloud
            |
            |internal object GeneratedCloudCatalog {
            |    const val VERSION = $version
            |
            |    val providers: List<CloudProviderSpec> = listOf(
            |${providers.trimEnd('\n')}
            |    )
            |
            |    val transcriptionModels: List<CloudModelSpec> = listOf(
            |${models.trimEnd('\n')}
            |    )
            |
            |    val cleanupModels: List<CleanupModelSpec> = listOf(
            |${cleanupModels.trimEnd('\n')}
            |    )
            |
            |    val cleanupModelSuccessors: Map<String, String> = mapOf(
            |${successors.trimEnd('\n')}
            |    )
            |
            |    /** SpeakCore's `TranscriptionLanguageCatalog.options`; the first is Automatic. */
            |    val languages: List<TranscriptionLanguageSpec> = listOf(
            |${languages.trimEnd('\n')}
            |    )
            |
            |    const val KEYWORD_PROMPT_MAX_BYTES = ${keywordPrompt["maximumBytes"] as Int}
            |    const val KEYWORD_PROMPT_MAX_TERMS = ${keywordPrompt["maximumTerms"] as Int}
            |
            |    const val CLEANUP_MODEL = ${lit(cleanup["model"])}
            |    const val CLEANUP_PROVIDER = ${lit(cleanup["provider"])}
            |    const val CLEANUP_SYSTEM_PROMPT = ${lit(cleanup["systemPrompt"])}
            |    const val CLEANUP_CUSTOM_PROMPT_CLOSING = ${lit(cleanup["customPromptClosing"])}
            |
            |    /** SpeakCore's `DictationProfile`: where profiles are stored and the fields they encode. */
            |    const val PROFILE_STORAGE_KEY = ${lit(profiles["storageKey"])}
            |    const val PROFILE_CLOUD_TRANSCRIPTION_ROUTING = ${lit(profiles["cloudTranscriptionRouting"])}
            |    val PROFILE_FIELDS: List<String> = listOf(
            |${profileFields.trimEnd('\n')}
            |    )
            |
            |    /** SpeakCore's `OpenRouterModelBrowserCatalog`: the shared browser copy and cleanup rows. */
            |    const val OPENROUTER_BROWSE_TITLE = ${lit(browser["browseButtonTitle"])}
            |    const val OPENROUTER_CLEANUP_TITLE = ${lit(browser["cleanupTitle"])}
            |    const val OPENROUTER_CLEANUP_INTRO = ${lit(browser["cleanupIntro"])}
            |    const val OPENROUTER_SEARCH_PLACEHOLDER = ${lit(browser["searchPlaceholder"])}
            |    const val OPENROUTER_ALL_PROVIDERS = ${lit(browser["allProvidersTitle"])}
            |    const val OPENROUTER_ZERO_PRICES = ${lit(browser["zeroPricesTitle"])}
            |    const val OPENROUTER_PRICING_CAVEAT = ${lit(browser["pricingCaveat"])}
            |    const val OPENROUTER_PRICING_UNLISTED = ${lit(browser["pricingUnlisted"])}
            |    const val OPENROUTER_CLEANUP_USE = ${lit(browser["useTitle"])}
            |    const val OPENROUTER_CLEANUP_SELECTED = ${lit(browser["selectedTitle"])}
            |    const val OPENROUTER_CLEANUP_ROUTE_NOTE = ${lit(browser["routeNote"])}
            |
            |    val openRouterCleanupModels: List<OpenRouterBrowserModelSpec> = listOf(
            |${browserModels.trimEnd('\n')}
            |    )
            |
            |    /** SpeakCore's `VoiceEditPolicy`: the selection-rewrite prompt and the formatting words. */
            |    const val VOICE_EDIT_SYSTEM_PROMPT = ${lit(voiceEdit["systemPrompt"])}
            |    const val VOICE_EDIT_USER_MESSAGE_INTRO = ${lit(voiceEdit["userMessageIntro"])}
            |    val VOICE_EDIT_QUOTE_TERMS: List<String> = ${strings(voiceEdit["quoteTerms"])}
            |    val VOICE_EDIT_CODE_FENCE_TERMS: List<String> = ${strings(voiceEdit["codeFenceTerms"])}
            |    val VOICE_EDIT_WHITESPACE_TERMS: List<String> = ${strings(voiceEdit["whitespaceTerms"])}
            |}
            |
        """.trimMargin()
        val dir = outputDir.get().asFile.resolve("com/justspeaktoit/android/cloud")
        dir.mkdirs()
        dir.resolve("GeneratedCloudCatalog.kt").writeText(source)
    }
}

val generateCloudCatalog = tasks.register<GenerateCloudCatalog>("generateCloudCatalog") {
    catalog.set(layout.projectDirectory.file("src/main/assets/cloud_catalog.json"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.java?.addGeneratedSourceDirectory(generateCloudCatalog, GenerateCloudCatalog::outputDir)
    }
}

// Zero Kotlin compiler warnings, like every other linter in the repository.
kotlin {
    compilerOptions {
        allWarningsAsErrors.set(true)
    }
}
