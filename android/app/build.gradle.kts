import groovy.json.JsonSlurper

// Play upload signing. CI decodes the upload keystore from the main-only `android-release`
// environment (Docs/android-play-store-submission.md); without it the release bundle is unsigned.
val uploadKeystore = providers.environmentVariable("JSTI_ANDROID_KEYSTORE_PATH").orNull
// Play rejects a version code it has seen, so CI supplies a monotonically increasing one.
val ciVersionCode = providers.environmentVariable("JSTI_ANDROID_VERSION_CODE").orNull?.toInt()

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
        val json = JsonSlurper().parse(catalog.get().asFile) as Map<String, Any?>
        val version = json["version"] as Int
        check(version == 1) { "cloud_catalog.json version $version is not understood; update this generator" }
        fun lit(value: Any?): String = "\"" + value.toString()
            .replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$")
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "\""
        @Suppress("UNCHECKED_CAST")
        fun objects(key: String) = json[key] as List<Map<String, Any?>>
        @Suppress("UNCHECKED_CAST")
        val cleanup = json["cleanup"] as Map<String, Any?>
        val providers = objects("providers").joinToString("") {
            "        CloudProviderSpec(id = ${lit(it["id"])}, credentialId = ${lit(it["credentialId"])}),\n"
        }
        val models = objects("transcriptionModels").joinToString("") {
            "        CloudModelSpec(\n" +
                "            catalogId = ${lit(it["catalogId"])},\n" +
                "            displayName = ${lit(it["displayName"])},\n" +
                "            providerId = ${lit(it["provider"])},\n" +
                "            apiName = ${lit(it["apiName"])},\n" +
                "            languageField = ${lit(it["languageField"])},\n" +
                "            supportsPrompt = ${it["supportsPrompt"] as Boolean},\n" +
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
        val profiles = json["profiles"] as Map<String, Any?>
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
