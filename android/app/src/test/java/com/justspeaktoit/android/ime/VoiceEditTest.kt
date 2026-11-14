package com.justspeaktoit.android.ime

import com.justspeaktoit.android.cloud.CallHandle
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.RequestReleasedException
import com.justspeaktoit.android.cloud.VoiceEditPolicy
import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.dictation.FakeCloud
import com.justspeaktoit.android.dictation.MemorySecrets
import com.justspeaktoit.android.security.SecretStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.GeneralSecurityException

class VoiceEditTest {
    private val model = CloudCatalog.cleanupModel(null)
    private val target = VoiceEditTarget("com.example.notes", 7, 4, 9, "hello")
    private val cloud = FakeCloud()

    private fun rewriter(secrets: SecretStore = MemorySecrets(model.provider.credentialId to "sk-test")) =
        VoiceEditRewriter(cloud, secrets)

    @Test
    fun testCapture_needsANonEmptySelectionTheEditorReturns() {
        assertNull(VoiceEditRules.capture("com.example.notes", 7, 4, 4, ""))
        assertNull(VoiceEditRules.capture("com.example.notes", 7, -1, -1, null))
        assertNull(VoiceEditRules.capture("com.example.notes", 7, 4, 9, null))
        assertNull(VoiceEditRules.capture("com.example.notes", 7, 4, 9, ""))
        assertEquals(target, VoiceEditRules.capture("com.example.notes", 7, 4, 9, "hello"))
    }

    @Test
    fun testCapture_ordersABackwardSelection() {
        assertEquals(target, VoiceEditRules.capture("com.example.notes", 7, 9, 4, "hello"))
    }

    @Test
    fun testStillTargets_onlyTheSameFieldRangeAndTextInTheSameInput() {
        assertTrue(VoiceEditRules.stillTargets(target, target.copy(), sameInput = true))
        listOf(
            target.copy(packageName = "com.example.chat"),
            target.copy(fieldId = 8),
            target.copy(selectionStart = 5),
            target.copy(selectionEnd = 10),
            target.copy(selectedText = "hullo"),
            null,
        ).forEach { current -> assertFalse("$current", VoiceEditRules.stillTargets(target, current, sameInput = true)) }
        // The input view restarted (for example on another field with the same id): never replace.
        assertFalse(VoiceEditRules.stillTargets(target, target, sameInput = false))
    }

    @Test
    fun testModel_prefersTheActiveProfileThenTheSavedCleanupModel() {
        val other = CloudCatalog.cleanupModels.first { it != model }
        assertEquals(other, VoiceEditRules.model(other, model.selectionId))
        assertEquals(other, VoiceEditRules.model(null, other.selectionId))
        assertEquals(model, VoiceEditRules.model(null, null))
    }

    @Test
    fun testReadKey_reportsAMissingOrUnreadableKey() {
        assertEquals(
            VoiceEditKey.Missing(VoiceEditFailure.MissingKey(model.provider)),
            rewriter(MemorySecrets()).readKey(model),
        )
        assertEquals(
            VoiceEditKey.Missing(VoiceEditFailure.MissingKey(model.provider)),
            rewriter(MemorySecrets(model.provider.credentialId to " ")).readKey(model),
        )
        val locked = object : SecretStore {
            override fun read(name: String): String? = throw GeneralSecurityException("locked")

            override fun write(name: String, value: String) = Unit

            override fun remove(name: String) = Unit

            override fun names(): Set<String> = emptySet()
        }
        assertEquals(VoiceEditKey.Missing(VoiceEditFailure.KeyUnavailable), rewriter(locked).readKey(model))
        val found = rewriter().readKey(model)
        assertTrue(found is VoiceEditKey.Found && found.value == "sk-test")
    }

    @Test
    fun testRewrite_sendsTheSharedPromptAndCleansTheReply() {
        cloud.onRewrite = { "\"Hi.\"\n" }
        val outcome = rewriter().rewrite(model, "sk-test", "hello", "  make it shorter \n", CallHandle())
        assertEquals(VoiceEditOutcome.Rewritten("Hi."), outcome)
        val sent = cloud.rewrites.single()
        assertEquals(model, sent.model)
        assertEquals("sk-test", sent.apiKey)
        assertEquals(VoiceEditPolicy.systemPrompt, sent.systemPrompt)
        assertEquals(VoiceEditPolicy.userMessage("hello", "make it shorter"), sent.userMessage)
    }

    @Test
    fun testRewrite_withoutAnInstructionOrSelection_sendsNothing() {
        assertEquals(
            VoiceEditOutcome.Failed(VoiceEditFailure.EmptyInstruction),
            rewriter().rewrite(model, "sk-test", "hello", " \n", CallHandle()),
        )
        assertEquals(
            VoiceEditOutcome.Failed(VoiceEditFailure.NoSelection),
            rewriter().rewrite(model, "sk-test", "", "make it shorter", CallHandle()),
        )
        assertTrue(cloud.rewrites.isEmpty())
    }

    @Test
    fun testRewrite_reportsAnEmptyReplyOrRequestFailureRatherThanReplacing() {
        cloud.onRewrite = { "  \n" }
        assertEquals(
            VoiceEditOutcome.Failed(VoiceEditFailure.EmptyRewrite),
            rewriter().rewrite(model, "sk-test", "hello", "delete it", CallHandle()),
        )
        cloud.onRewrite = { throw CloudException(DictationFailure.Network, "offline") }
        assertEquals(
            VoiceEditOutcome.Failed(VoiceEditFailure.Request(DictationFailure.Network)),
            rewriter().rewrite(model, "sk-test", "hello", "make it shorter", CallHandle()),
        )
    }

    @Test
    fun testRewrite_cancelledOrReleasedByTheUser_isNotAFailure() {
        cloud.onRewrite = { call ->
            call.cancel()
            throw CloudException(DictationFailure.Network, "disconnected")
        }
        assertEquals(VoiceEditOutcome.Cancelled, rewriter().rewrite(model, "sk-test", "hello", "shorter", CallHandle()))
        cloud.onRewrite = { throw RequestReleasedException() }
        assertEquals(VoiceEditOutcome.Cancelled, rewriter().rewrite(model, "sk-test", "hello", "shorter", CallHandle()))
    }
}
