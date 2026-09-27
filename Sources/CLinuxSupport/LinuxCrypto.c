#include "LinuxSupportInternal.h"

#include <gnutls/crypto.h>
#include <gnutls/gnutls.h>
#include <string.h>

/*
 * PBKDF2-HMAC-SHA256, AES-256-GCM and random bytes from GnuTLS (the GNOME
 * platform's TLS library), for the API-key sync envelope. These are the
 * primitives the Apple (CryptoKit) and Windows (CNG) adapters supply; nothing
 * here is a hand-written cipher. Keys and plaintexts are wiped from scratch
 * buffers before they are released.
 */

enum { NONCE_BYTES = 12, TAG_BYTES = 16, KEY_BYTES = 32 };

static int32_t gnutls_failure(char *error, size_t capacity, const char *action, int code) {
    jsti_set_error(error, capacity, "Could not %s: %s", action, gnutls_strerror(code));
    return -1;
}

int32_t jsti_crypto_pbkdf2_sha256(
    const uint8_t *password, size_t password_count, const uint8_t *salt, size_t salt_count, uint64_t iterations,
    uint8_t *key, size_t key_count, char *error, size_t capacity) {
    if (iterations == 0 || iterations > UINT32_MAX || key_count == 0) {
        jsti_set_error(error, capacity, "The key derivation parameters are invalid.");
        return -1;
    }
    gnutls_datum_t secret = { .data = (unsigned char *)password, .size = (unsigned int)password_count };
    gnutls_datum_t pepper = { .data = (unsigned char *)salt, .size = (unsigned int)salt_count };
    int code = gnutls_pbkdf2(GNUTLS_MAC_SHA256, &secret, &pepper, (unsigned)iterations, key, key_count);
    return code < 0 ? gnutls_failure(error, capacity, "derive the sync key", code) : 0;
}

int32_t jsti_crypto_random(uint8_t *bytes, size_t count, char *error, size_t capacity) {
    int code = gnutls_rnd(GNUTLS_RND_KEY, bytes, count);
    return code < 0 ? gnutls_failure(error, capacity, "generate random bytes", code) : 0;
}

static int32_t open_cipher(
    gnutls_aead_cipher_hd_t *handle, const uint8_t *key, size_t key_count, char *error, size_t capacity) {
    if (key_count != KEY_BYTES) {
        jsti_set_error(error, capacity, "The sync key has the wrong length.");
        return -1;
    }
    gnutls_datum_t datum = { .data = (unsigned char *)key, .size = KEY_BYTES };
    int code = gnutls_aead_cipher_init(handle, GNUTLS_CIPHER_AES_256_GCM, &datum);
    return code < 0 ? gnutls_failure(error, capacity, "prepare AES-GCM", code) : 0;
}

int32_t jsti_crypto_aes_gcm_seal(
    const uint8_t *key, size_t key_count, const uint8_t *plaintext, size_t plaintext_count, uint8_t *nonce,
    uint8_t *ciphertext, uint8_t *tag, char *error, size_t capacity) {
    gnutls_aead_cipher_hd_t handle = NULL;
    if (open_cipher(&handle, key, key_count, error, capacity) != 0) return -1;
    int32_t result = -1;
    size_t sealed_count = plaintext_count + TAG_BYTES;
    uint8_t *sealed = g_malloc0(sealed_count);
    int code = gnutls_rnd(GNUTLS_RND_NONCE, nonce, NONCE_BYTES);
    if (code < 0) {
        gnutls_failure(error, capacity, "generate a nonce", code);
    } else {
        code = gnutls_aead_cipher_encrypt(
            handle, nonce, NONCE_BYTES, NULL, 0, TAG_BYTES, plaintext, plaintext_count, sealed, &sealed_count);
        if (code < 0) {
            gnutls_failure(error, capacity, "encrypt with AES-GCM", code);
        } else if (sealed_count != plaintext_count + TAG_BYTES) {
            jsti_set_error(error, capacity, "AES-GCM returned an unexpected length.");
        } else {
            if (plaintext_count > 0) memcpy(ciphertext, sealed, plaintext_count);
            memcpy(tag, sealed + plaintext_count, TAG_BYTES);
            result = 0;
        }
    }
    gnutls_memset(sealed, 0, plaintext_count + TAG_BYTES);
    g_free(sealed);
    gnutls_aead_cipher_deinit(handle);
    return result;
}

int32_t jsti_crypto_aes_gcm_open(
    const uint8_t *key, size_t key_count, const uint8_t *nonce, const uint8_t *ciphertext, size_t ciphertext_count,
    const uint8_t *tag, uint8_t *plaintext, char *error, size_t capacity) {
    gnutls_aead_cipher_hd_t handle = NULL;
    if (open_cipher(&handle, key, key_count, error, capacity) != 0) return -1;
    size_t sealed_count = ciphertext_count + TAG_BYTES;
    uint8_t *sealed = g_malloc(sealed_count);
    if (ciphertext_count > 0) memcpy(sealed, ciphertext, ciphertext_count);
    memcpy(sealed + ciphertext_count, tag, TAG_BYTES);
    size_t opened_count = ciphertext_count;
    int code = gnutls_aead_cipher_decrypt(
        handle, nonce, NONCE_BYTES, NULL, 0, TAG_BYTES, sealed, sealed_count, plaintext, &opened_count);
    g_free(sealed);
    gnutls_aead_cipher_deinit(handle);
    if (code < 0 || opened_count != ciphertext_count) {
        if (ciphertext_count > 0) gnutls_memset(plaintext, 0, ciphertext_count);
        jsti_set_error(error, capacity, "The sealed value could not be opened with this key.");
        return -1;
    }
    return 0;
}
