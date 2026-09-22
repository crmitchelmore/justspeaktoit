#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <wincred.h>

namespace {
bool credentialName(const char *name, std::wstring &result) {
    std::wstring suffix;
    if (!jsti::wide(name, suffix) || suffix.empty()) return false;
    result = L"com.justspeaktoit/" + suffix;
    return result.size() <= CRED_MAX_GENERIC_TARGET_NAME_LENGTH;
}
}

int jsti_credential_write(const char *name, const uint8_t *bytes, size_t count, char *error, size_t capacity) {
    std::wstring target;
    if (!credentialName(name, target) || (!bytes && count) || count > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
        return jsti::fail("Invalid credential name or credential exceeds Windows Credential Manager capacity.", error, capacity);
    }
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = &target[0];
    credential.CredentialBlobSize = static_cast<DWORD>(count);
    credential.CredentialBlob = const_cast<LPBYTE>(bytes);
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    if (!CredWriteW(&credential, 0)) return jsti::fail(jsti::systemError("Saving credential"), error, capacity);
    return 0;
}

int jsti_credential_read(const char *name, uint8_t *bytes, size_t capacity, size_t *count,
                         char *error, size_t errorCapacity) {
    if (count) *count = 0;
    std::wstring target;
    if (!count || !credentialName(name, target)) return jsti::fail("Invalid credential request.", error, errorCapacity);
    PCREDENTIALW credential = nullptr;
    if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
        const DWORD code = GetLastError();
        if (code == ERROR_NOT_FOUND) return 1;
        return jsti::fail(jsti::systemError("Reading credential", code), error, errorCapacity);
    }
    *count = credential->CredentialBlobSize;
    const bool fits = *count <= capacity && (bytes || *count == 0);
    if (fits && *count) std::memcpy(bytes, credential->CredentialBlob, *count);
    if (credential->CredentialBlobSize) SecureZeroMemory(credential->CredentialBlob, credential->CredentialBlobSize);
    CredFree(credential);
    return fits ? 0 : 2;
}

int jsti_credential_delete(const char *name, char *error, size_t capacity) {
    std::wstring target;
    if (!credentialName(name, target)) return jsti::fail("Invalid credential name.", error, capacity);
    if (!CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0)) {
        const DWORD code = GetLastError();
        if (code != ERROR_NOT_FOUND) return jsti::fail(jsti::systemError("Deleting credential", code), error, capacity);
    }
    return 0;
}
