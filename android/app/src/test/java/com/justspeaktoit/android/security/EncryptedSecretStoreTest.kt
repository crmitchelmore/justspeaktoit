package com.justspeaktoit.android.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.GeneralSecurityException
import java.util.Base64
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

class EncryptedSecretStoreTest {
    private class MapBacking : SecretBacking {
        val map = linkedMapOf<String, String>()
        override fun get(key: String) = map[key]
        override fun put(key: String, value: String) {
            map[key] = value
        }
        override fun delete(key: String) {
            map.remove(key)
        }
        override fun keys(): Set<String> = map.keys.toSet()
    }

    private fun newKey(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    private val key = newKey()
    private val backing = MapBacking()
    private val store = EncryptedSecretStore(backing) { key }

    @Test
    fun testWriteRead_roundTripsWithoutStoringPlaintext() {
        store.write("OPENAI_API_KEY", "sk-test-123")
        assertEquals("sk-test-123", store.read("OPENAI_API_KEY"))
        assertFalse(backing.map.getValue("OPENAI_API_KEY").contains("sk-test-123"))
        assertTrue(backing.map.getValue("OPENAI_API_KEY").startsWith("v1:"))
    }

    @Test
    fun testSealing_usesFreshIvEachTime() {
        val a = SealedBox.seal(key, "same".toByteArray(), "N".toByteArray())
        val b = SealedBox.seal(key, "same".toByteArray(), "N".toByteArray())
        assertNotEquals(a, b)
    }

    @Test
    fun testCiphertextMovedToAnotherName_isRejectedAndRemoved() {
        store.write("DEEPGRAM_API_KEY", "dg-secret")
        backing.map["GROQ_API_KEY"] = backing.map.getValue("DEEPGRAM_API_KEY")
        assertNull(store.read("GROQ_API_KEY"))
        assertFalse(backing.map.containsKey("GROQ_API_KEY"))
        assertEquals("dg-secret", store.read("DEEPGRAM_API_KEY"))
    }

    @Test
    fun testLostKey_reportsAbsentAndClearsUndecryptableValue() {
        store.write("OPENAI_API_KEY", "sk-old")
        val restored = EncryptedSecretStore(backing) { newKey() }
        assertNull(restored.read("OPENAI_API_KEY"))
        assertTrue(backing.map.isEmpty())
    }

    @Test
    fun testKeyProviderFailure_doesNotDeleteStoredValue() {
        store.write("OPENAI_API_KEY", "sk-keep")
        val unavailable = EncryptedSecretStore(backing) { throw GeneralSecurityException("keystore locked") }
        try {
            unavailable.read("OPENAI_API_KEY")
        } catch (expected: GeneralSecurityException) {
            // The failure must surface rather than look like a missing key.
        }
        assertEquals("sk-keep", store.read("OPENAI_API_KEY"))
    }

    @Test
    fun testTamperedValue_isRejected() {
        store.write("OPENAI_API_KEY", "sk-test")
        val bytes = Base64.getDecoder().decode(backing.map.getValue("OPENAI_API_KEY").removePrefix("v1:"))
        bytes[bytes.size - 1] = (bytes[bytes.size - 1].toInt() xor 1).toByte()
        backing.map["OPENAI_API_KEY"] = "v1:" + Base64.getEncoder().encodeToString(bytes)
        assertNull(store.read("OPENAI_API_KEY"))
    }

    @Test
    fun testMalformedValues_areRejected() {
        listOf("", "v1:", "v1:!!!", "v2:AAAA", "v1:AAAA").forEach { bad ->
            try {
                SealedBox.open(key, bad, ByteArray(0))
                throw AssertionError("Expected rejection for '$bad'")
            } catch (expected: GeneralSecurityException) {
                // Rejected as intended.
            }
        }
    }

    @Test
    fun testEmptyValueAndRemove_deleteEntries() {
        store.write("A_KEY", "x")
        store.write("A_KEY", "")
        assertNull(store.read("A_KEY"))
        store.write("B_KEY", "y")
        store.remove("B_KEY")
        assertTrue(store.names().isEmpty())
    }

    @Test
    fun testNames_listsOnlyValidSecretNames() {
        store.write("B_KEY", "1")
        store.write("A_KEY", "2")
        backing.map["unrelated.pref"] = "x"
        assertEquals(listOf("A_KEY", "B_KEY"), store.names().toList())
    }

    @Test(expected = IllegalArgumentException::class)
    fun testInvalidName_isRejected() {
        store.write("openai key", "x")
    }
}
