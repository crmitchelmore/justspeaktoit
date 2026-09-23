#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <bcrypt.h>
#include <cstdio>
#include <new>
#include <vector>

// CNG's SHA-256 verifies downloaded model files. The provider handle is opened
// per digest: model downloads are rare and this keeps objects independent.
struct JSTISHA256 {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    std::vector<UCHAR> object;
    bool finished = false;
};

namespace {
std::string cngError(const char *operation, NTSTATUS status) {
    char code[16] = {};
    std::snprintf(code, sizeof code, "%08lx", static_cast<unsigned long>(status));
    return std::string(operation) + " failed (NTSTATUS 0x" + code + ").";
}
}

extern "C" JSTISHA256 *jsti_sha256_create(char *error, size_t capacity) {
    auto *hasher = new (std::nothrow) JSTISHA256();
    if (!hasher) { jsti::fail("Could not allocate a SHA-256 digest.", error, capacity); return nullptr; }
    NTSTATUS status = BCryptOpenAlgorithmProvider(&hasher->algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
    if (!BCRYPT_SUCCESS(status)) {
        jsti::fail(cngError("Opening the Windows SHA-256 provider", status), error, capacity);
        delete hasher;
        return nullptr;
    }
    DWORD objectLength = 0, written = 0;
    status = BCryptGetProperty(hasher->algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectLength),
                               sizeof objectLength, &written, 0);
    if (BCRYPT_SUCCESS(status)) {
        try { hasher->object.resize(objectLength); } catch (const std::bad_alloc &) { status = static_cast<NTSTATUS>(0xC0000017L); }
    }
    if (BCRYPT_SUCCESS(status)) {
        status = BCryptCreateHash(hasher->algorithm, &hasher->hash, hasher->object.data(),
                                  static_cast<ULONG>(hasher->object.size()), nullptr, 0, 0);
    }
    if (!BCRYPT_SUCCESS(status)) {
        jsti::fail(cngError("Creating a Windows SHA-256 digest", status), error, capacity);
        jsti_sha256_destroy(hasher);
        return nullptr;
    }
    return hasher;
}

extern "C" int jsti_sha256_update(JSTISHA256 *hasher, const void *bytes, size_t count, char *error,
                                  size_t capacity) {
    if (!hasher || !hasher->hash || hasher->finished || (count && !bytes)) {
        return jsti::fail("The SHA-256 digest is not open.", error, capacity);
    }
    const auto *cursor = static_cast<const UCHAR *>(bytes);
    while (count) {
        const ULONG chunk = static_cast<ULONG>(std::min<size_t>(count, 1u << 30));
        const NTSTATUS status = BCryptHashData(hasher->hash, const_cast<PUCHAR>(cursor), chunk, 0);
        if (!BCRYPT_SUCCESS(status)) return jsti::fail(cngError("Hashing with Windows SHA-256", status), error, capacity);
        cursor += chunk;
        count -= chunk;
    }
    return 0;
}

extern "C" int jsti_sha256_finish(JSTISHA256 *hasher, char *hex, size_t hexCapacity, char *error, size_t capacity) {
    if (!hasher || !hasher->hash || hasher->finished) return jsti::fail("The SHA-256 digest is not open.", error, capacity);
    if (!hex || hexCapacity < 65) return jsti::fail("The SHA-256 output buffer is too small.", error, capacity);
    UCHAR digest[32] = {};
    hasher->finished = true;
    const NTSTATUS status = BCryptFinishHash(hasher->hash, digest, sizeof digest, 0);
    if (!BCRYPT_SUCCESS(status)) return jsti::fail(cngError("Finishing the Windows SHA-256 digest", status), error, capacity);
    static const char digits[] = "0123456789abcdef";
    for (size_t index = 0; index < sizeof digest; ++index) {
        hex[index * 2] = digits[digest[index] >> 4];
        hex[index * 2 + 1] = digits[digest[index] & 15];
    }
    hex[64] = 0;
    return 0;
}

extern "C" void jsti_sha256_destroy(JSTISHA256 *hasher) {
    if (!hasher) return;
    if (hasher->hash) BCryptDestroyHash(hasher->hash);
    if (hasher->algorithm) BCryptCloseAlgorithmProvider(hasher->algorithm, 0);
    delete hasher;
}
