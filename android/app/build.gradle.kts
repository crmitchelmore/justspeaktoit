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
        warningsAsErrors = false
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
