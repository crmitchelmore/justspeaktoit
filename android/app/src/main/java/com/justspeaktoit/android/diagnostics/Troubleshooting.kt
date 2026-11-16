package com.justspeaktoit.android.diagnostics

import org.json.JSONObject

/**
 * The phone Troubleshooting rules from `assets/troubleshooting.json`, which SpeakCore's
 * `MobileTroubleshootingAndroidExport` writes from `MobileTroubleshooting`, so Android and iOS give the same
 * verdicts and fixes. Raw values match the Swift enums.
 */
enum class TroubleshootingSeverity(val rawValue: String) { Issue("issue"), Warning("warning"), Info("info"), Ok("ok") }

enum class TroubleshootingCheck(val rawValue: String) {
    Microphone("microphone-permission"),
    SpeechRecognition("speech-recognition-permission"),
    Recogniser("recogniser"),
    TranscriptionKey("transcription-api-key"),
    PostProcessingKey("postprocessing-api-key"),
    Keyboard("keyboard"),
}

enum class TroubleshootingFix(val rawValue: String) {
    RequestMicrophone("requestMicrophone"),
    RequestSpeechRecognition("requestSpeechRecognition"),
    OpenSystemSettings("openSystemSettings"),
    OpenTranscriptionSettings("openTranscriptionSettings"),
    OpenApiKeys("openAPIKeys"),
    VerifyKey("verifyKey"),
    DisablePostProcessing("disablePostProcessing"),
    OpenKeyboardSetup("openKeyboardSetup"),
}

enum class MicrophoneState(val rawValue: String) {
    Granted("granted"),
    Denied("denied"),
    NotDetermined("notDetermined"),
}

/** Whether the recogniser the chosen dictation mode uses can run now. */
enum class RecogniserState(val rawValue: String) {
    /** The mode is Cloud, which needs a key instead. */
    NotRequired("notRequired"),
    Ready("ready"),
    NeedsDownload("needsDownload"),
    UnsupportedLanguage("unsupportedLanguage"),
    Unavailable("unavailable"),
    Unknown("unknown"),
}

enum class KeyState(val rawValue: String) {
    NotRequired("notRequired"),
    Present("present"),
    Missing("missing"),
    Rejected("rejected"),
    Unreadable("unreadable"),
}

enum class KeyboardState(val rawValue: String) { NotAdded("notAdded"), Ready("ready") }

/** The provider a key belongs to; [name] is null when no key is needed. */
data class TroubleshootingProvider(val name: String?, val key: KeyState) {
    companion object {
        val None = TroubleshootingProvider(null, KeyState.NotRequired)
    }
}

/** The facts Android gathers, mirroring `MobileTroubleshooting.Input`; Android has no speech permission. */
data class TroubleshootingInput(
    val microphone: MicrophoneState,
    val recogniser: RecogniserState,
    val transcription: TroubleshootingProvider,
    val postProcessingEnabled: Boolean,
    val postProcessing: TroubleshootingProvider,
    val keyboard: KeyboardState,
)

data class TroubleshootingFinding(
    val check: TroubleshootingCheck,
    val title: String,
    val detail: String,
    val severity: TroubleshootingSeverity,
    val fixes: List<TroubleshootingFix>,
)

class TroubleshootingRules private constructor(
    private val placeholder: String,
    /** Most severe first. */
    private val severities: List<TroubleshootingSeverity>,
    private val checks: List<Pair<TroubleshootingCheck, Map<String, TroubleshootingFinding>>>,
) {
    /** Every check that applies, problems first, then in the shared check order. */
    fun findings(input: TroubleshootingInput): List<TroubleshootingFinding> =
        checks.mapNotNull { (check, states) -> finding(check, states, input) }
            .sortedBy { severities.indexOf(it.severity) }

    private fun finding(
        check: TroubleshootingCheck,
        states: Map<String, TroubleshootingFinding>,
        input: TroubleshootingInput,
    ): TroubleshootingFinding? = when (check) {
        TroubleshootingCheck.Microphone -> states[input.microphone.rawValue]
        TroubleshootingCheck.SpeechRecognition -> null
        TroubleshootingCheck.Recogniser -> states[input.recogniser.rawValue]
        TroubleshootingCheck.TranscriptionKey -> keyFinding(states, input.transcription)
        TroubleshootingCheck.PostProcessingKey ->
            if (input.postProcessingEnabled) keyFinding(states, input.postProcessing) else null
        TroubleshootingCheck.Keyboard -> states[input.keyboard.rawValue]
    }

    private fun keyFinding(states: Map<String, TroubleshootingFinding>, provider: TroubleshootingProvider) =
        provider.name?.let { name ->
            states[provider.key.rawValue]?.let {
                it.copy(title = it.title.replace(placeholder, name), detail = it.detail.replace(placeholder, name))
            }
        }

    companion object {
        const val ASSET = "troubleshooting.json"
        private const val VERSION = 1

        /** The worst severity, which the summary line reports. */
        fun overall(findings: List<TroubleshootingFinding>): TroubleshootingSeverity =
            findings.minByOrNull { it.severity.ordinal }?.severity ?: TroubleshootingSeverity.Ok

        fun parse(json: String): TroubleshootingRules {
            val root = JSONObject(json)
            require(root.getInt("version") == VERSION) { "Unsupported troubleshooting rules version" }
            val severityArray = root.getJSONArray("severities")
            val severities = List(severityArray.length()) { severity(severityArray.getString(it)) }
            val checkArray = root.getJSONArray("checks")
            // A check this build does not know is skipped rather than shown without a way to evaluate it.
            val checks = List(checkArray.length()) { checkArray.getJSONObject(it) }.mapNotNull { item ->
                val check = TroubleshootingCheck.entries.firstOrNull { it.rawValue == item.getString("id") }
                    ?: return@mapNotNull null
                val states = item.getJSONObject("states")
                check to states.keys().asSequence().associateWith { state ->
                    val rule = states.getJSONObject(state)
                    val fixes = rule.getJSONArray("fixes")
                    TroubleshootingFinding(
                        check = check,
                        title = rule.getString("title"),
                        detail = rule.getString("detail"),
                        severity = severity(rule.getString("severity")),
                        fixes = List(fixes.length()) { fixes.getString(it) }.mapNotNull { raw ->
                            TroubleshootingFix.entries.firstOrNull { it.rawValue == raw }
                        },
                    )
                }
            }
            return TroubleshootingRules(root.getString("providerPlaceholder"), severities, checks)
        }

        private fun severity(raw: String): TroubleshootingSeverity =
            TroubleshootingSeverity.entries.first { it.rawValue == raw }
    }
}
