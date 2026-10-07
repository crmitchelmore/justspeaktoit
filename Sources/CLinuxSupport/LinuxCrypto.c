#include "LinuxSupportInternal.h"

#include <limits.h>
#include <string.h>

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>

/*
 * OpenSSL (libcrypto) primitives for the existing API-key sync envelope, as
 * WindowsCrypto.cpp calls CNG. The parameters (PBKDF2 iteration count, salt
 * layout, nonce and tag sizes) are chosen by the shared Swift envelope; this
 * file only calls the system's audited cryptography.
 */

enum { NONCE_BYTES = 12, TAG_BYTES = 16, KEY_BYTES = 32 };

/* Reports the first queued OpenSSL error, if any, and clears the queue. */
static int32_t crypto_fail(const char *operation, char *error, size_t capacity) {
    unsigned long code = ERR_get_error();
    ERR_clear_error();
    if (code == 0) {
        jsti_set_error(error, capacity, "%s failed.", operation);
    } else {
        char reason[160];
        ERR_error_string_n(code, reason, sizeof reason);
        jsti_set_error(error, capacity, "%s failed (%s).", operation, reason);
    }
    return -1;
}

static int32_t invalid(const char *message, char *error, size_t capacity) {
    jsti_set_error(error, capacity, "%s", message);
    return -1;
}

int32_t jsti_crypto_random(uint8_t *bytes, size_t count, char *error, size_t capacity) {
    if ((bytes == NULL && count != 0) || count > INT_MAX) return invalid("Invalid random request.", error, capacity);
    if (count == 0) return 0;
    return RAND_bytes(bytes, (int)count) == 1 ? 0 : crypto_fail("Generating random bytes", error, capacity);
}

int32_t jsti_crypto_pbkdf2_sha256(
    const uint8_t *password, size_t password_count, const uint8_t *salt, size_t salt_count, uint64_t iterations,
    uint8_t *key, size_t key_count, char *error, size_t capacity) {
    if ((password == NULL && password_count != 0) || (salt == NULL && salt_count != 0) || key == NULL ||
        key_count == 0 || iterations == 0 || iterations > INT_MAX || password_count > INT_MAX ||
        salt_count > INT_MAX || key_count > INT_MAX) {
        return invalid("Invalid key derivation request.", error, capacity);
    }
    static const uint8_t empty = 0;
    if (PKCS5_PBKDF2_HMAC(
            (const char *)(password_count != 0 ? password : &empty), (int)password_count,
            salt_count != 0 ? salt : &empty, (int)salt_count, (int)iterations, EVP_sha256(), (int)key_count,
            key) != 1) {
        OPENSSL_cleanse(key, key_count);
        return crypto_fail("Deriving the key", error, capacity);
    }
    return 0;
}

/* A GCM context with a 256-bit key and a 96-bit nonce, for sealing or opening. */
static EVP_CIPHER_CTX *gcm_context(const uint8_t *secret, size_t secret_count, const uint8_t *nonce, int encrypt) {
    if (secret == NULL || secret_count != KEY_BYTES) return NULL;
    EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
    if (context == NULL) return NULL;
    if (EVP_CipherInit_ex(context, EVP_aes_256_gcm(), NULL, NULL, NULL, encrypt) != 1 ||
        EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_IVLEN, NONCE_BYTES, NULL) != 1 ||
        EVP_CipherInit_ex(context, NULL, NULL, secret, nonce, encrypt) != 1) {
        EVP_CIPHER_CTX_free(context);
        return NULL;
    }
    return context;
}

int32_t jsti_crypto_aes_gcm_seal(
    const uint8_t *secret, size_t secret_count, const uint8_t *plaintext, size_t count, uint8_t *nonce,
    uint8_t *ciphertext, uint8_t *tag, char *error, size_t capacity) {
    if ((plaintext == NULL && count != 0) || (ciphertext == NULL && count != 0) || nonce == NULL || tag == NULL ||
        count > INT_MAX) {
        return invalid("Invalid encryption request.", error, capacity);
    }
    if (secret == NULL || secret_count != KEY_BYTES) return invalid("The key is not 256 bits.", error, capacity);
    if (jsti_crypto_random(nonce, NONCE_BYTES, error, capacity) != 0) return -1;
    EVP_CIPHER_CTX *context = gcm_context(secret, secret_count, nonce, 1);
    if (context == NULL) return crypto_fail("Preparing encryption", error, capacity);
    int written = 0, finished = 0;
    uint8_t rest[16];
    gboolean sealed = (count == 0 || EVP_EncryptUpdate(context, ciphertext, &written, plaintext, (int)count) == 1) &&
        EVP_EncryptFinal_ex(context, rest, &finished) == 1 && finished == 0 && (size_t)written == count &&
        EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_GET_TAG, TAG_BYTES, tag) == 1;
    EVP_CIPHER_CTX_free(context);
    if (!sealed) {
        if (count != 0) OPENSSL_cleanse(ciphertext, count);
        return crypto_fail("Encrypting", error, capacity);
    }
    return 0;
}

int32_t jsti_crypto_aes_gcm_open(
    const uint8_t *secret, size_t secret_count, const uint8_t *nonce, const uint8_t *ciphertext, size_t count,
    const uint8_t *tag, uint8_t *plaintext, char *error, size_t capacity) {
    if ((ciphertext == NULL && count != 0) || (plaintext == NULL && count != 0) || nonce == NULL || tag == NULL ||
        count > INT_MAX) {
        return invalid("Invalid decryption request.", error, capacity);
    }
    if (secret == NULL || secret_count != KEY_BYTES) return invalid("The key is not 256 bits.", error, capacity);
    EVP_CIPHER_CTX *context = gcm_context(secret, secret_count, nonce, 0);
    if (context == NULL) return crypto_fail("Preparing decryption", error, capacity);
    int written = 0, finished = 0;
    uint8_t expected[TAG_BYTES], rest[16];
    memcpy(expected, tag, TAG_BYTES);
    gboolean decrypted = (count == 0 || EVP_DecryptUpdate(context, plaintext, &written, ciphertext, (int)count) == 1) &&
        (size_t)written == count && EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_TAG, TAG_BYTES, expected) == 1;
    /* Final checks the tag: nothing decrypted is released unless it verifies. */
    gboolean verified = decrypted && EVP_DecryptFinal_ex(context, rest, &finished) == 1 && finished == 0;
    EVP_CIPHER_CTX_free(context);
    if (verified) return 0;
    if (count != 0) OPENSSL_cleanse(plaintext, count);
    if (!decrypted) return crypto_fail("Decrypting", error, capacity);
    ERR_clear_error();
    jsti_set_error(error, capacity, "The encrypted value did not verify.");
    return 1;
}
