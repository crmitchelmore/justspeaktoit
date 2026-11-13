package com.justspeaktoit.android.telemetry

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.justspeaktoit.android.BuildConfig
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.dictation.RecognitionMode
import java.util.Locale

/** The app's analytics and crash reporting, both off until the user opts in. */
class Telemetry(
    private val store: TelemetryStore,
    val analytics: ProductAnalytics,
    val crashes: CrashReportingGate,
) {
    val analyticsEnabled: Boolean get() = store.analyticsConsent.permitsCollection
    val diagnosticsEnabled: Boolean get() = store.diagnosticsConsent.permitsCollection
    val needsConsentPrompt: Boolean get() = store.needsConsentPrompt

    /** The first-run prompt's answer. Both switches start off, so dismissing it declines both. */
    fun recordFirstRunChoices(analyticsOptIn: Boolean, diagnosticsGranted: Boolean) {
        if (store.analyticsConsent == AnalyticsConsent.Unknown) {
            analytics.setOptedIn(analyticsOptIn, OptInSurface.Onboarding)
        }
        if (store.diagnosticsConsent == DiagnosticsConsent.Undecided) crashes.setGranted(diagnosticsGranted)
    }

    fun transcriptionSucceeded(mode: RecognitionMode, cloudModel: CloudModel) {
        val (provider, engine) = classify(mode, cloudModel)
        analytics.transcriptionSucceeded(provider, engine)
    }

    companion object {
        /** On-device and speech-service recognisers belong to the phone's vendor, so their provider is "other". */
        fun classify(mode: RecognitionMode, cloudModel: CloudModel): Pair<ProviderType, EngineType> = when (mode) {
            RecognitionMode.OnDevice -> ProviderType.Other to EngineType.OnDevice
            RecognitionMode.SpeechService -> ProviderType.Other to EngineType.Cloud
            RecognitionMode.Cloud -> ProviderType.forProviderId(cloudModel.provider.id) to EngineType.Cloud
        }

        fun create(context: Context): Telemetry {
            val store = TelemetryPreferences(context)
            val version = "${BuildConfig.VERSION_NAME}+${BuildConfig.VERSION_CODE}"
            val crashes = CrashReportingGate(
                store,
                SentryCrashReporter(
                    context,
                    release = "justspeaktoit-android@$version",
                    environment = if (installedFromPlay(context)) "production" else "alpha",
                ),
                enabledInBuild = !BuildConfig.DEBUG,
            )
            val analytics = ProductAnalytics(
                store,
                AnalyticsContext(
                    appVersion = BuildConfig.VERSION_NAME,
                    build = BuildConfig.VERSION_CODE.toString(),
                    osMajorMinor = Build.VERSION.RELEASE.orEmpty(),
                    distributionChannel = when {
                        BuildConfig.DEBUG -> DistributionChannel.Development
                        installedFromPlay(context) -> DistributionChannel.GooglePlay
                        else -> DistributionChannel.Direct
                    },
                    localeLanguageCode = Locale.getDefault().language,
                    architecture = Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
                ),
                PostHogTransport(BuildConfig.POSTHOG_PROJECT_KEY),
            )
            return Telemetry(store, analytics, crashes)
        }

        private fun installedFromPlay(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
            val installer = try {
                context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName
            } catch (_: PackageManager.NameNotFoundException) {
                null
            }
            return installer == PLAY_STORE
        }

        private const val PLAY_STORE = "com.android.vending"
    }
}
