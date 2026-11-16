package com.justspeaktoit.android.ime

import com.justspeaktoit.android.cloud.CallHandle
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.CloudService
import com.justspeaktoit.android.cloud.RequestReleasedException
import com.justspeaktoit.android.cloud.VoiceEditPolicy
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.security.SecretStore
import java.security.GeneralSecurityException
import java.security.ProviderException

/** The field and selection a voice edit started on; the rewrite may replace only this. */
internal data class VoiceEditTarget(
    val packageName: String?,
    val fieldId: Int,
    val selectionStart: Int,
    val selectionEnd: Int,
    val selectedText: String,
)

/** Why a voice edit left the text as it was. */
internal sealed interface VoiceEditFailure {
    data object NoSelection : VoiceEditFailure

    /** No API key is saved for the cleanup model's provider. */
    data class MissingKey(val provider: CloudProvider) : VoiceEditFailure

    data object KeyUnavailable : VoiceEditFailure

    data object EmptyInstruction : VoiceEditFailure

    data object EmptyRewrite : VoiceEditFailure

    /** The field, selection or selected text changed while the edit ran. */
    data object TargetChanged : VoiceEditFailure

    /** Recognising the spoken instruction failed. */
    data class Recognition(val failure: DictationFailure) : VoiceEditFailure

    /** The cleanup provider request failed. */
    data class Request(val failure: DictationFailure) : VoiceEditFailure
}

internal sealed interface VoiceEditOutcome {
    data class Rewritten(val text: String) : VoiceEditOutcome

    data class Failed(val failure: VoiceEditFailure) : VoiceEditOutcome

    data object Cancelled : VoiceEditOutcome
}

/** A saved key, or why there is none. Not a data class, so the key never reaches a log through toString. */
internal sealed interface VoiceEditKey {
    class Found(val value: String) : VoiceEditKey

    data class Missing(val failure: VoiceEditFailure) : VoiceEditKey
}

/** The keyboard's voice-edit decisions, kept free of Android types so they run in JVM tests. */
internal object VoiceEditRules {
    /**
     * The target for a selection the editor reported, or null when nothing is selected or the
     * editor would not return the selected text (some fields refuse to).
     */
    fun capture(
        packageName: String?,
        fieldId: Int,
        selectionStart: Int,
        selectionEnd: Int,
        selectedText: CharSequence?,
    ): VoiceEditTarget? {
        if (selectionStart < 0 || selectionEnd < 0 || selectionStart == selectionEnd) return null
        val text = selectedText?.toString()
        if (text.isNullOrEmpty()) return null
        return VoiceEditTarget(
            packageName = packageName,
            fieldId = fieldId,
            selectionStart = minOf(selectionStart, selectionEnd),
            selectionEnd = maxOf(selectionStart, selectionEnd),
            selectedText = text,
        )
    }

    /**
     * Whether the rewrite may replace [current]: only the same input session, field, range and text
     * that the edit started on. Anything else could overwrite text the user did not select.
     */
    fun stillTargets(captured: VoiceEditTarget, current: VoiceEditTarget?, sameInput: Boolean): Boolean =
        sameInput && current == captured

    /** The profile's cleanup model, else the user's: the same model dictation cleanup uses. */
    fun model(profileModel: CleanupModel?, savedModelId: String?): CleanupModel =
        profileModel ?: CloudCatalog.cleanupModel(savedModelId)
}

/**
 * Rewrites a selection with the cleanup model, using SpeakCore's [VoiceEditPolicy] prompt. Both calls
 * block, so run them off the main thread; neither touches the editor.
 */
internal class VoiceEditRewriter(
    private val cloud: CloudService,
    private val secrets: SecretStore,
) {
    fun readKey(model: CleanupModel): VoiceEditKey = try {
        secrets.read(model.provider.credentialId)
            ?.takeIf { it.isNotBlank() }
            ?.let { VoiceEditKey.Found(it) }
            ?: VoiceEditKey.Missing(VoiceEditFailure.MissingKey(model.provider))
    } catch (e: GeneralSecurityException) {
        VoiceEditKey.Missing(VoiceEditFailure.KeyUnavailable)
    } catch (e: ProviderException) {
        VoiceEditKey.Missing(VoiceEditFailure.KeyUnavailable)
    }

    fun rewrite(
        model: CleanupModel,
        apiKey: String,
        selection: String,
        spokenInstruction: String,
        call: CallHandle,
    ): VoiceEditOutcome {
        if (selection.isEmpty()) return VoiceEditOutcome.Failed(VoiceEditFailure.NoSelection)
        val instruction = VoiceEditPolicy.normalizedInstruction(spokenInstruction)
        if (instruction.isEmpty()) return VoiceEditOutcome.Failed(VoiceEditFailure.EmptyInstruction)
        return try {
            val reply = cloud.rewriteSelection(
                model = model,
                apiKey = apiKey,
                systemPrompt = VoiceEditPolicy.systemPrompt,
                userMessage = VoiceEditPolicy.userMessage(selection, instruction),
                call = call,
            )
            val text = VoiceEditPolicy.normalizedRewrite(reply, selection, instruction)
            if (text.isEmpty()) {
                VoiceEditOutcome.Failed(VoiceEditFailure.EmptyRewrite)
            } else {
                VoiceEditOutcome.Rewritten(text)
            }
        } catch (e: RequestReleasedException) {
            VoiceEditOutcome.Cancelled
        } catch (e: CloudException) {
            // A cancelled call fails as a network error; the user asked for it, so it is not one.
            if (call.cancelled) {
                VoiceEditOutcome.Cancelled
            } else {
                VoiceEditOutcome.Failed(VoiceEditFailure.Request(e.failure))
            }
        }
    }
}
