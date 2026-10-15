#include "../Sources/CWindowsSupport/WindowsSupportInternal.hpp"
#include <aclapi.h>
#include <sddl.h>
#include <winternl.h>
#include <objbase.h>
#include <cstdio>
#include <type_traits>

#if !defined(_WIN64) || (!defined(_M_X64) && !defined(__x86_64__))
#error This diagnostic requires the Windows x64 function-pointer ABI.
#endif

namespace diagnostic {
using SetInformation = NTSTATUS (NTAPI *)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, ULONG);
static_assert(std::is_same_v<FARPROC, INT_PTR (WINAPI *)()>);
static_assert(sizeof(FARPROC) == 8 && sizeof(SetInformation) == sizeof(FARPROC));
SetInformation realSetInformation = nullptr;
const char *phase = "startup";
unsigned failures = 0;
NTSTATUS NTAPI setInformation(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, ULONG);
FARPROC WINAPI resolve(HMODULE, LPCSTR);
NTSTATUS NTAPI create(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK,
                     PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);
static_assert(std::is_same_v<decltype(&setInformation), SetInformation>);

// Win64 SDK generic procedure addresses retain their representation, not their signature.
template<typename To, typename From>
bool procedureAddress(const From &source, To &destination) {
    static_assert(std::is_pointer_v<From> && std::is_pointer_v<To>);
    static_assert(std::is_function_v<std::remove_pointer_t<From>>);
    static_assert(std::is_function_v<std::remove_pointer_t<To>>);
    static_assert(std::is_trivially_copyable_v<From> && std::is_trivially_copyable_v<To>);
    static_assert(sizeof(From) == sizeof(To) && sizeof(To) == sizeof(FARPROC));
    std::memcpy(&destination, &source, sizeof(destination));
    From roundtrip{};
    std::memcpy(&roundtrip, &destination, sizeof(roundtrip));
    return roundtrip == source && (source == nullptr) == (destination == nullptr);
}
}

// Only this standalone translation unit interposes; the app's C source is unchanged.
#define GetProcAddress diagnostic::resolve
#define NtCreateFile diagnostic::create
#include "../Sources/CWindowsSupport/WindowsFileSecurity.cpp"
#undef NtCreateFile
#undef GetProcAddress

namespace diagnostic {
FARPROC WINAPI resolve(HMODULE module, LPCSTR name) {
    const FARPROC result = ::GetProcAddress(module, name);
    const DWORD error = GetLastError();
    if (reinterpret_cast<uintptr_t>(name) > 0xffff && std::strcmp(name, "NtSetInformationFile") == 0) {
        FARPROC forwarded = nullptr;
        const bool verified = procedureAddress(result, realSetInformation) &&
                              (!result || procedureAddress(&setInformation, forwarded));
        unsigned char representation[sizeof(result)]{};
        std::memcpy(representation, &result, sizeof(result));
        std::printf("resolver actualRepresentation=");
        for (unsigned char byte : representation) std::printf("%02x", static_cast<unsigned>(byte));
        std::printf(" lastError=%lu typedRoundtrip=%u\n", error, static_cast<unsigned>(verified));
        if (!verified) {
            ++failures;
            realSetInformation = nullptr;
            std::printf("diagnostic-error operation=function-pointer representation\n");
        }
        SetLastError(error);
        return verified ? forwarded : nullptr;
    }
    SetLastError(error);
    return result;
}

NTSTATUS NTAPI create(PHANDLE result, ACCESS_MASK access, POBJECT_ATTRIBUTES attributes,
                     PIO_STATUS_BLOCK io, PLARGE_INTEGER size, ULONG fileAttributes, ULONG sharing,
                     ULONG disposition, ULONG options, PVOID ea, ULONG eaSize) {
    const DWORD incoming = GetLastError();
    std::printf("ntcreate phase=%s access=%08lx share=%08lx disposition=%lu options=%08lx root=%p",
                phase, access, sharing, disposition, options, attributes ? attributes->RootDirectory : nullptr);
    if (attributes && attributes->ObjectName) {
        std::printf(" name=%.*ls", static_cast<int>(attributes->ObjectName->Length / sizeof(wchar_t)),
                    attributes->ObjectName->Buffer);
    }
    std::printf("\n");
    SetLastError(incoming);
    const NTSTATUS status = ::NtCreateFile(result, access, attributes, io, size, fileAttributes,
                                          sharing, disposition, options, ea, eaSize);
    const DWORD error = GetLastError();
    std::printf("ntcreate-return phase=%s status=%08lx handle=%p lastError=%lu\n",
                phase, static_cast<unsigned long>(status), result ? *result : nullptr, error);
    SetLastError(error);
    return status;
}

NTSTATUS NTAPI setInformation(HANDLE file, PIO_STATUS_BLOCK io, PVOID info, ULONG bytes, ULONG kind) {
    const DWORD incoming = GetLastError();
    std::printf("ntset phase=%s file=%p class=%lu bytes=%lu", phase, file, kind, bytes);
    if (kind == 10 && info && bytes >= offsetof(RegistryRenameInformationV2, FileName)) {
        BOOLEAN replace = FALSE;
        HANDLE root = nullptr;
        ULONG nameBytes = 0;
        const auto *storage = static_cast<const BYTE *>(info);
        std::memcpy(&replace, storage, sizeof(replace));
        std::memcpy(&root, storage + offsetof(RegistryRenameInformationV2, RootDirectory), sizeof(root));
        std::memcpy(&nameBytes, storage + offsetof(RegistryRenameInformationV2, FileNameLength), sizeof(nameBytes));
        std::printf(" replace=%u root=%p nameBytes=%lu layout=%zu/%zu/%zu/%zu",
                    static_cast<unsigned>(replace), root,
                    nameBytes, sizeof(RegistryRenameInformationV2),
                    offsetof(RegistryRenameInformationV2, RootDirectory),
                    offsetof(RegistryRenameInformationV2, FileNameLength),
                    offsetof(RegistryRenameInformationV2, FileName));
    }
    std::printf("\n");
    SetLastError(incoming);
    const NTSTATUS status = realSetInformation(file, io, info, bytes, kind);
    const DWORD error = GetLastError();
    const DWORD mapped = RtlNtStatusToDosError(status);
    std::printf("ntset-return phase=%s status=%08lx mapped=%lu lastError=%lu\n",
                phase, static_cast<unsigned long>(status), mapped, error);
    SetLastError(error);
    return status;
}

void failed(const char *operation, DWORD error) {
    ++failures;
    std::printf("diagnostic-error operation=%s error=%lu\n", operation, error);
}

void sid(const char *label, PSID value) {
    LPWSTR text = nullptr;
    if (!value || !ConvertSidToStringSidW(value, &text)) {
        failed(label, GetLastError());
        return;
    }
    std::printf("%s=%ls\n", label, text);
    if (LocalFree(text)) failed("LocalFree SID", GetLastError());
}

bool inspect(const std::wstring &path, const PrivateSecurity &security, bool required) {
    const HANDLE handle = CreateFileW(path.c_str(), READ_CONTROL | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
        const DWORD error = GetLastError();
        std::printf("inspect phase=%s path=%ls openError=%lu required=%u\n",
                    phase, path.c_str(), error, static_cast<unsigned>(required));
        if (required || (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)) failed("inspect open", error);
        return false;
    }
    PSID owner = nullptr;
    PACL acl = nullptr;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    const DWORD error = GetSecurityInfo(handle, SE_FILE_OBJECT,
        OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &owner, nullptr, &acl, nullptr, &descriptor);
    std::printf("inspect phase=%s path=%ls securityError=%lu\n", phase, path.c_str(), error);
    if (error == ERROR_SUCCESS) {
        sid("actualOwner", owner);
        DWORD nativeError = 0;
        const auto predicate = privateDescriptorCheck(owner, acl, descriptor, security, nativeError);
        SECURITY_DESCRIPTOR_CONTROL control = 0;
        DWORD revision = 0;
        if (!GetSecurityDescriptorControl(descriptor, &control, &revision)) failed("descriptor control", GetLastError());
        std::printf("ownerMatches=%u privatePredicate=%u nativeError=%lu control=%04x aceCount=%u\n",
            static_cast<unsigned>(owner && EqualSid(owner, security.userSID())),
            static_cast<unsigned>(predicate), nativeError, static_cast<unsigned>(control),
            acl ? static_cast<unsigned>(acl->AceCount) : 0);
        for (DWORD index = 0; acl && index < acl->AceCount; ++index) {
            void *raw = nullptr;
            if (!GetAce(acl, index, &raw)) { failed("GetAce", GetLastError()); break; }
            const auto *entry = static_cast<const ACCESS_ALLOWED_ACE *>(raw);
            std::printf("ace index=%lu type=%u flags=%u size=%u\n", index,
                static_cast<unsigned>(entry->Header.AceType), static_cast<unsigned>(entry->Header.AceFlags),
                static_cast<unsigned>(entry->Header.AceSize));
            if (entry->Header.AceType == ACCESS_ALLOWED_ACE_TYPE) {
                std::printf("mask=%08lx\n", entry->Mask);
                sid("trustee", const_cast<DWORD *>(&entry->SidStart));
            }
        }
        FILE_ID_INFO identity{};
        FILE_ATTRIBUTE_TAG_INFO attributes{};
        if (!GetFileInformationByHandleEx(handle, FileIdInfo, &identity, sizeof(identity)) ||
            !GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &attributes, sizeof(attributes))) {
            failed("inspect identity/attributes", GetLastError());
        } else {
            std::printf("volume=%llu attributes=%08lx id=", identity.VolumeSerialNumber, attributes.FileAttributes);
            for (BYTE byte : identity.FileId.Identifier) std::printf("%02x", static_cast<unsigned>(byte));
            std::printf("\n");
        }
    } else failed("GetSecurityInfo", error);
    if (descriptor && LocalFree(descriptor)) failed("LocalFree descriptor", GetLastError());
    if (!CloseHandle(handle)) failed("inspect CloseHandle", GetLastError());
    return error == ERROR_SUCCESS;
}

JSTIRegistryOutcomeV2 outcome() {
    JSTIRegistryOutcomeV2 value{};
    value.abi_version = JSTI_REGISTRY_ABI_V2;
    value.struct_size = static_cast<uint32_t>(sizeof(value));
    return value;
}

void report(const char *operation, int result, const JSTIRegistryOutcomeV2 &value) {
    std::printf("v2 phase=%s operation=%s result=%d effect=%u causes=%u closes=%u unconfirmed=%u poisoned=%u\n",
        phase, operation, result, value.effect, value.cause_count, value.close_attempt_count,
        value.release_unconfirmed_count, value.capability_poisoned);
    for (uint32_t index = 0; index < value.cause_count && index < JSTI_REGISTRY_MAX_CAUSES_V2; ++index) {
        const auto &cause = value.causes[index];
        std::printf("cause kind=%u domain=%u code=%u stage=%u resource=%llu\n",
            cause.kind, cause.domain, cause.native_code, cause.stage, cause.resource_id);
    }
    if (result) ++failures;
}

bool closeV2(JSTIRecordingRegistryV2 *&registry) {
    auto value = outcome();
    const int result = jsti_recording_registry_close_v2(registry, &value);
    report("close", result, value);
    value = outcome();
    const int destroyed = jsti_recording_registry_destroy_v2(&registry, &value);
    report("destroy", destroyed, value);
    return result == 0 && destroyed == 0;
}

void v2(const std::wstring &history, const PrivateSecurity &security) {
    const std::string path = jsti::utf8(history);
    JSTIRecordingRegistryV2 *registry = nullptr;
    phase = "v2-open";
    inspect(history, security, true);
    auto value = outcome();
    int result = jsti_recording_registry_open_v2(reinterpret_cast<const uint8_t *>(path.data()),
                                                path.size(), 1, &registry, &value);
    report("open", result, value);
    inspect(history + L"\\.recording-locations", security, false);
    if (result) return;
    const std::string leaf = "registry.jloc";
    const std::string payload = "JSTI native capability fixture, not a codec registration";
    phase = "v2-append";
    value = outcome();
    result = jsti_recording_registry_append_v2(registry, reinterpret_cast<const uint8_t *>(leaf.data()),
        leaf.size(), reinterpret_cast<const uint8_t *>(payload.data()), payload.size(), nullptr, nullptr, &value);
    report("append", result, value);
    phase = "v2-close";
    if (!closeV2(registry) || result) return;
    phase = "v2-reopen";
    value = outcome();
    result = jsti_recording_registry_open_v2(reinterpret_cast<const uint8_t *>(path.data()),
                                            path.size(), 0, &registry, &value);
    report("reopen", result, value);
    if (result) return;
    std::array<uint8_t, 256> bytes{};
    size_t count = 0;
    value = outcome();
    result = jsti_recording_registry_read_v2(registry, reinterpret_cast<const uint8_t *>(leaf.data()),
                                            leaf.size(), bytes.data(), bytes.size(), &count, &value);
    report("read", result, value);
    if (!result && (count != payload.size() || std::memcmp(bytes.data(), payload.data(), count))) {
        failed("V2 payload equality", ERROR_INVALID_DATA);
    }
    closeV2(registry);
}

void legacy(const std::wstring &history, const PrivateSecurity &security) {
    const auto path = jsti::utf8(history);
    char detail[1024]{};
    JSTIRecordingRegistry *registry = nullptr;
    phase = "legacy-open";
    inspect(history, security, true);
    int result = jsti_recording_registry_open(path.c_str(), 1, &registry, detail, sizeof(detail));
    std::printf("legacy open result=%d detail=%s\n", result, detail);
    if (result) { ++failures; return; }
    inspect(history + L"\\.recording-locations", security, true);
    const std::array<uint8_t, 8> payload{'J', 'S', 'T', 'I', 'R', 'E', 'G', 1};
    int effect = -1;
    phase = "legacy-append";
    result = jsti_recording_registry_append(registry, "registry.jloc", payload.data(), payload.size(),
                                            nullptr, nullptr, &effect, detail, sizeof(detail));
    std::printf("legacy append result=%d effect=%d detail=%s\n", result, effect, detail);
    if (result || effect != 1) ++failures;
    const bool appended = result == 0 && effect == 1;
    phase = "legacy-close";
    result = jsti_recording_registry_close(registry, detail, sizeof(detail));
    std::printf("legacy close result=%d detail=%s\n", result, detail);
    if (result) ++failures;
    jsti_recording_registry_destroy(registry);
    if (!appended || result) return;
    phase = "legacy-reopen";
    registry = nullptr;
    result = jsti_recording_registry_open(path.c_str(), 0, &registry, detail, sizeof(detail));
    std::printf("legacy reopen result=%d detail=%s\n", result, detail);
    if (result) { ++failures; return; }
    result = jsti_recording_registry_close(registry, detail, sizeof(detail));
    std::printf("legacy reopened close result=%d detail=%s\n", result, detail);
    if (result) ++failures;
    jsti_recording_registry_destroy(registry);
}
}

int main() {
    using namespace diagnostic;
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("DIAGNOSTIC ONLY: native results are observations, not factory qualification; no root cleanup/repair.\n");
    std::printf("compilerMSC=%d win32WinNT=%x handleBytes=%zu\n", _MSC_VER, _WIN32_WINNT, sizeof(HANDLE));
    PrivateSecurity security;
    std::string error;
    if (!security.initialise(error)) { std::printf("token-error=%s\n", error.c_str()); return 3; }
    sid("tokenUser", security.userSID());
    jsti::Handle token;
    if (!OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &token.value)) {
        const DWORD error = GetLastError();
        if (error != ERROR_NO_TOKEN || !OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token.value)) {
            failed("effective token", error == ERROR_NO_TOKEN ? GetLastError() : error);
            return 3;
        }
    }
    DWORD needed = 0;
    GetTokenInformation(token.value, TokenOwner, nullptr, 0, &needed);
    if (!needed) { failed("TokenOwner size", GetLastError()); return 3; }
    std::vector<BYTE> owner(needed);
    if (!GetTokenInformation(token.value, TokenOwner, owner.data(), needed, &needed)) {
        failed("TokenOwner", GetLastError()); return 3;
    }
    sid("effectiveTokenDefaultOwner", reinterpret_cast<TOKEN_OWNER *>(owner.data())->Owner);
    wchar_t temporary[MAX_PATH + 1]{};
    const DWORD count = GetTempPathW(MAX_PATH + 1, temporary);
    if (!count || count > MAX_PATH) { failed("GetTempPath", GetLastError()); return 3; }
    GUID guid{};
    wchar_t identifier[40]{};
    const HRESULT allocated = CoCreateGuid(&guid);
    if (FAILED(allocated)) {
        std::printf("diagnostic-error operation=CoCreateGuid hresult=%08lx\n", static_cast<unsigned long>(allocated));
        return 3;
    }
    if (!StringFromGUID2(guid, identifier, 40)) { failed("StringFromGUID2", GetLastError()); return 3; }
    const std::wstring base = std::wstring(temporary) + L"jsti-registry-diagnostic-" + identifier;
    const std::wstring defaultHistory = base + L"-Default";
    const std::wstring privateHistory = base + L"-Private";
    const std::wstring legacyHistory = base + L"-Legacy";
    std::printf("defaultHistory=%ls privateHistory=%ls legacyHistory=%ls\n",
                defaultHistory.c_str(), privateHistory.c_str(), legacyHistory.c_str());
    if (!CreateDirectoryW(defaultHistory.c_str(), nullptr)) { failed("exclusive default create", GetLastError()); return 3; }
    std::printf("comparison=Win32 default-descriptor creation, NOT Foundation equivalence\n");
    v2(defaultHistory, security);
    char detail[1024]{};
    phase = "private-positive-create";
    int result = jsti_private_directory_create(jsti::utf8(privateHistory).c_str(), detail, sizeof(detail));
    std::printf("private-create result=%d detail=%s\n", result, detail);
    if (!result) v2(privateHistory, security); else ++failures;
    phase = "legacy-private-create";
    result = jsti_private_directory_create(jsti::utf8(legacyHistory).c_str(), detail, sizeof(detail));
    std::printf("legacy-private-create result=%d detail=%s\n", result, detail);
    if (!result) legacy(legacyHistory, security); else ++failures;
    std::printf("diagnostic-failures=%u syntheticRootsRetained=1\n", failures);
    return failures ? 2 : 0;
}
