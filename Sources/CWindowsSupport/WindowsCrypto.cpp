#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <bcrypt.h>
#include <climits>
#include <vector>

// CNG primitives for the existing API-key sync envelope. Parameters (PBKDF2
// iteration count, salt layout, nonce and tag sizes) are chosen by the shared
// Swift envelope; this file only calls audited Windows cryptography.

#ifndef NT_SUCCESS
#define NT_SUCCESS(status) (((NTSTATUS)(status)) >= 0)
#endif
#ifndef STATUS_AUTH_TAG_MISMATCH
#define STATUS_AUTH_TAG_MISMATCH ((NTSTATUS)0xC000A002L)
#endif

namespace {
constexpr ULONG nonceBytes = 12, tagBytes = 16;

std::string cngError(const char *operation, NTSTATUS status) {
    return std::string(operation) + " failed (CNG status " + std::to_string(static_cast<unsigned long>(status)) + ").";
}

struct Algorithm {
    BCRYPT_ALG_HANDLE handle = nullptr;
    ~Algorithm() { if (handle) BCryptCloseAlgorithmProvider(handle, 0); }
};

struct Key {
    BCRYPT_KEY_HANDLE handle = nullptr;
    std::vector<UCHAR> object;
    ~Key() { if (handle) BCryptDestroyKey(handle); if (!object.empty()) SecureZeroMemory(object.data(), object.size()); }
};

// Opens AES in GCM mode and imports a 256-bit key.
NTSTATUS gcmKey(const uint8_t *secret, size_t count, Algorithm &algorithm, Key &key) {
    if (!secret || count != 32) return static_cast<NTSTATUS>(0xC000000DL); // STATUS_INVALID_PARAMETER
    NTSTATUS status = BCryptOpenAlgorithmProvider(&algorithm.handle, BCRYPT_AES_ALGORITHM, nullptr, 0);
    if (!NT_SUCCESS(status)) return status;
    status = BCryptSetProperty(algorithm.handle, BCRYPT_CHAINING_MODE,
        reinterpret_cast<PUCHAR>(const_cast<wchar_t *>(BCRYPT_CHAIN_MODE_GCM)),
        static_cast<ULONG>(sizeof(BCRYPT_CHAIN_MODE_GCM)), 0);
    if (!NT_SUCCESS(status)) return status;
    DWORD objectLength = 0;
    ULONG written = 0;
    status = BCryptGetProperty(algorithm.handle, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectLength),
                               sizeof(objectLength), &written, 0);
    if (!NT_SUCCESS(status)) return status;
    key.object.resize(objectLength);
    return BCryptGenerateSymmetricKey(algorithm.handle, &key.handle, key.object.data(), objectLength,
                                      const_cast<PUCHAR>(secret), static_cast<ULONG>(count), 0);
}

BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO gcmInfo(uint8_t *nonce, uint8_t *tag) {
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = nonce;
    info.cbNonce = nonceBytes;
    info.pbTag = tag;
    info.cbTag = tagBytes;
    return info;
}
} // namespace

int jsti_crypto_random(uint8_t *bytes, size_t count, char *error, size_t capacity) {
    if ((!bytes && count) || count > ULONG_MAX) return jsti::fail("Invalid random request.", error, capacity);
    if (!count) return 0;
    const NTSTATUS status = BCryptGenRandom(nullptr, bytes, static_cast<ULONG>(count), BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    return NT_SUCCESS(status) ? 0 : jsti::fail(cngError("Generating random bytes", status), error, capacity);
}

int jsti_crypto_pbkdf2_sha256(const uint8_t *password, size_t passwordCount, const uint8_t *salt, size_t saltCount,
                              uint64_t iterations, uint8_t *key, size_t keyCount, char *error, size_t capacity) {
    if ((!password && passwordCount) || (!salt && saltCount) || !key || !keyCount || !iterations ||
        passwordCount > ULONG_MAX || saltCount > ULONG_MAX || keyCount > ULONG_MAX) {
        return jsti::fail("Invalid key derivation request.", error, capacity);
    }
    Algorithm hmac;
    NTSTATUS status = BCryptOpenAlgorithmProvider(&hmac.handle, BCRYPT_SHA256_ALGORITHM, nullptr,
                                                  BCRYPT_ALG_HANDLE_HMAC_FLAG);
    if (NT_SUCCESS(status)) {
        // CNG rejects a null password pointer even for an empty password.
        UCHAR empty = 0;
        status = BCryptDeriveKeyPBKDF2(hmac.handle, passwordCount ? const_cast<PUCHAR>(password) : &empty,
            static_cast<ULONG>(passwordCount), saltCount ? const_cast<PUCHAR>(salt) : &empty,
            static_cast<ULONG>(saltCount), iterations, key, static_cast<ULONG>(keyCount), 0);
    }
    return NT_SUCCESS(status) ? 0 : jsti::fail(cngError("Deriving the key", status), error, capacity);
}

int jsti_crypto_aes_gcm_seal(const uint8_t *secret, size_t secretCount, const uint8_t *plaintext, size_t count,
                             uint8_t *nonce, uint8_t *ciphertext, uint8_t *tag, char *error, size_t capacity) {
    if ((!plaintext && count) || (!ciphertext && count) || !nonce || !tag || count > ULONG_MAX) {
        return jsti::fail("Invalid encryption request.", error, capacity);
    }
    if (jsti_crypto_random(nonce, nonceBytes, error, capacity) != 0) return -1;
    Algorithm algorithm;
    Key key;
    NTSTATUS status = gcmKey(secret, secretCount, algorithm, key);
    if (NT_SUCCESS(status)) {
        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info = gcmInfo(nonce, tag);
        ULONG written = 0;
        UCHAR empty = 0;
        status = BCryptEncrypt(key.handle, count ? const_cast<PUCHAR>(plaintext) : &empty, static_cast<ULONG>(count),
                               &info, nullptr, 0, count ? ciphertext : &empty, static_cast<ULONG>(count), &written, 0);
        if (NT_SUCCESS(status) && written != count) status = static_cast<NTSTATUS>(0xC0000001L);
    }
    return NT_SUCCESS(status) ? 0 : jsti::fail(cngError("Encrypting", status), error, capacity);
}

int jsti_crypto_aes_gcm_open(const uint8_t *secret, size_t secretCount, const uint8_t *nonce,
                             const uint8_t *ciphertext, size_t count, const uint8_t *tag, uint8_t *plaintext,
                             char *error, size_t capacity) {
    if ((!ciphertext && count) || (!plaintext && count) || !nonce || !tag || count > ULONG_MAX) {
        return jsti::fail("Invalid decryption request.", error, capacity);
    }
    Algorithm algorithm;
    Key key;
    NTSTATUS status = gcmKey(secret, secretCount, algorithm, key);
    if (NT_SUCCESS(status)) {
        uint8_t nonceCopy[nonceBytes];
        uint8_t tagCopy[tagBytes];
        std::memcpy(nonceCopy, nonce, nonceBytes);
        std::memcpy(tagCopy, tag, tagBytes);
        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info = gcmInfo(nonceCopy, tagCopy);
        ULONG written = 0;
        UCHAR empty = 0;
        status = BCryptDecrypt(key.handle, count ? const_cast<PUCHAR>(ciphertext) : &empty, static_cast<ULONG>(count),
                               &info, nullptr, 0, count ? plaintext : &empty, static_cast<ULONG>(count), &written, 0);
        if (status == STATUS_AUTH_TAG_MISMATCH) {
            if (count) SecureZeroMemory(plaintext, count);
            jsti::fail("The encrypted value did not verify.", error, capacity);
            return 1;
        }
        if (NT_SUCCESS(status) && written != count) status = static_cast<NTSTATUS>(0xC0000001L);
    }
    if (!NT_SUCCESS(status) && count) SecureZeroMemory(plaintext, count);
    return NT_SUCCESS(status) ? 0 : jsti::fail(cngError("Decrypting", status), error, capacity);
}
