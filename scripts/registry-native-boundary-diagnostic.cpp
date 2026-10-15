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
void borrowedSnapshot(const char *, HANDLE);

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
        std::printf("\n");
        borrowedSnapshot("staging", file);
        borrowedSnapshot("destination", root);
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

void borrowedSnapshot(const char *label, HANDLE handle) {
    const DWORD incoming = GetLastError();
    PUBLIC_OBJECT_BASIC_INFORMATION access{};
    ULONG returned = 0;
    const NTSTATUS status = ::NtQueryObject(handle, ObjectBasicInformation, &access,
                                            static_cast<ULONG>(sizeof(access)), &returned);
    std::printf("borrowed phase=%s role=%s handle=%p accessQueryStatus=%08lx returnedBytes=%lu shareMaskNotQueried=1\n",
                phase, label, handle, static_cast<unsigned long>(status), returned);
    if (status < 0 || returned != sizeof(access)) {
        failed("borrowed granted-access query", status < 0 ? RtlNtStatusToDosError(status) : ERROR_BAD_LENGTH);
    } else {
        std::printf("borrowed role=%s queriedGrantedAccess=%08lx\n", label, access.GrantedAccess);
    }
    FILE_ID_INFO identity{};
    FILE_BASIC_INFO basic{};
    if (!GetFileInformationByHandleEx(handle, FileIdInfo, &identity, sizeof(identity)) ||
        !GetFileInformationByHandleEx(handle, FileBasicInfo, &basic, sizeof(basic))) {
        failed("borrowed identity/basic query", GetLastError());
    } else {
        std::printf("borrowed role=%s volume=%llu id=", label, identity.VolumeSerialNumber);
        for (BYTE byte : identity.FileId.Identifier) std::printf("%02x", static_cast<unsigned>(byte));
        std::printf(" attributes=%08lx creation=%lld access=%lld write=%lld change=%lld\n",
                    basic.FileAttributes, static_cast<long long>(basic.CreationTime.QuadPart),
                    static_cast<long long>(basic.LastAccessTime.QuadPart),
                    static_cast<long long>(basic.LastWriteTime.QuadPart),
                    static_cast<long long>(basic.ChangeTime.QuadPart));
    }
    SetLastError(incoming);
}

bool controlClose(jsti::Handle &handle, const char *label) {
    if (!handle.value || handle.value == INVALID_HANDLE_VALUE) return true;
    const HANDLE owned = handle.value;
    handle.value = nullptr;
    const BOOL closed = CloseHandle(owned);
    const DWORD error = closed ? ERROR_SUCCESS : GetLastError();
    std::printf("primitive-close phase=%s role=%s success=%u error=%lu\n",
                phase, label, static_cast<unsigned>(closed != FALSE), error);
    if (!closed) failed("primitive owned CloseHandle", error);
    return closed != FALSE;
}

bool controlIdentity(HANDLE handle, FILE_ID_INFO &identity) {
    if (!GetFileInformationByHandleEx(handle, FileIdInfo, &identity, sizeof(identity))) {
        failed("primitive identity", GetLastError());
        return false;
    }
    return true;
}

bool sameControlIdentity(const FILE_ID_INFO &first, const FILE_ID_INFO &second) {
    return first.VolumeSerialNumber == second.VolumeSerialNumber &&
           std::memcmp(first.FileId.Identifier, second.FileId.Identifier, sizeof(first.FileId.Identifier)) == 0;
}

bool controlBytes(HANDLE directory, const std::wstring &name, const std::string &payload,
                  const FILE_ID_INFO &expected, const PrivateSecurity &security, bool sealed) {
    jsti::Handle reader;
    std::string detail;
    bool valid = openRelative(directory, name, FILE_READ_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL,
        FILE_OPEN, false, nullptr, reader, detail, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
    if (!valid) std::printf("primitive-error phase=%s operation=read-open detail=%s\n", phase, detail.c_str());
    if (valid) {
        FILE_ID_INFO identity{};
        std::array<char, 256> bytes{};
        DWORD count = 0;
        valid = registryFile(reader.value, security, sealed, detail) && controlIdentity(reader.value, identity) &&
            sameControlIdentity(expected, identity);
        if (valid && !ReadFile(reader.value, bytes.data(), static_cast<DWORD>(bytes.size()), &count, nullptr)) {
            failed("primitive ReadFile", GetLastError());
            valid = false;
        }
        valid = valid && count == payload.size() && std::memcmp(bytes.data(), payload.data(), count) == 0;
    }
    if (!valid) {
        std::printf("primitive-error phase=%s operation=exact-bytes-identity-private-ACL detail=%s\n",
                    phase, detail.c_str());
        failed("primitive exact bytes/identity/private ACL", ERROR_INVALID_DATA);
    }
    return controlClose(reader, "exact-reader") && valid;
}

struct PrimitiveCase {
    const char *name;
    bool directoryDelete;
    ULONG directoryShare;
    ULONG stagingShare;
    bool sealBefore;
};

void primitive(const std::wstring &base, const PrimitiveCase &test, bool legacyTuple,
               const PrivateSecurity &security) {
    const std::string label = std::string(legacyTuple ? "primitive-legacy-" : "primitive-v2-") + test.name;
    phase = label.c_str();
    const std::wstring history = base + L"-" + std::wstring(label.begin(), label.end());
    char error[1024]{};
    const int created = jsti_private_directory_create(jsti::utf8(history).c_str(), error, sizeof(error));
    std::printf("primitive-create phase=%s result=%d detail=%s freshRootsRetained=1 notFullBackend=1\n",
                phase, created, error);
    if (created) { ++failures; return; }
    std::vector<std::wstring> components;
    std::vector<std::unique_ptr<jsti::Handle>> parents;
    jsti::Handle heldHistory, directory, file;
    std::string detail;
    bool published = false, admitted = false, fileCreated = false;
    const std::string payload = legacyTuple ? std::string("JSTIREG\1", 8) :
        "JSTI native capability fixture, not a codec registration";
    const ACCESS_MASK directoryAccess = READ_CONTROL | FILE_LIST_DIRECTORY | FILE_ADD_FILE |
        FILE_TRAVERSE | FILE_READ_ATTRIBUTES | (test.directoryDelete ? DELETE : 0);
    const ACCESS_MASK stagingAccess = FILE_WRITE_DATA | FILE_WRITE_ATTRIBUTES | FILE_READ_ATTRIBUTES |
        READ_CONTROL | DELETE | (legacyTuple ? 0 : FILE_READ_DATA);
    const unsigned changed = static_cast<unsigned>(!test.directoryDelete) +
        static_cast<unsigned>(test.directoryShare != (FILE_SHARE_READ | FILE_SHARE_WRITE)) +
        static_cast<unsigned>(test.stagingShare != FILE_SHARE_READ) + static_cast<unsigned>(!test.sealBefore);
    std::printf("primitive-tuple phase=%s changedKnobs=%u declaredDirectoryAccess=%08lx "
                "declaredDirectoryShare=%08lx declaredStagingAccess=%08lx declaredStagingShare=%08lx sealBefore=%u\n",
                phase, changed, directoryAccess | SYNCHRONIZE, test.directoryShare,
                stagingAccess | SYNCHRONIZE, test.stagingShare, static_cast<unsigned>(test.sealBefore));
    do {
        if (changed > 1) { failed("primitive one-knob invariant", ERROR_INVALID_DATA); break; }
        if (!parsePath(jsti::utf8(history).c_str(), components, detail) ||
            !openParents(components, parents, detail) ||
            !openRelative(parents.back()->value, components.back(), FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL,
                FILE_OPEN, true, nullptr, heldHistory, detail) ||
            !verifyPrivate(heldHistory.value, security, detail) ||
            !openRelative(heldHistory.value, L".recording-locations", directoryAccess,
                FILE_CREATE, true, const_cast<SECURITY_DESCRIPTOR *>(&security.descriptor), directory, detail,
                test.directoryShare) || !verifyPrivate(directory.value, security, detail)) {
            std::printf("primitive-error phase=%s operation=admission detail=%s\n", phase, detail.c_str());
            ++failures;
            break;
        }
        FILE_ID_INFO directoryIdentity{}, fileIdentity{}, current{};
        if (!controlIdentity(directory.value, directoryIdentity)) break;
        const std::wstring target = history + L"\\.recording-locations\\registry.jloc";
        const DWORD attributes = GetFileAttributesW(target.c_str());
        const DWORD absentError = GetLastError();
        if (attributes != INVALID_FILE_ATTRIBUTES || absentError != ERROR_FILE_NOT_FOUND) {
            failed("primitive target must be absent", attributes == INVALID_FILE_ATTRIBUTES ? absentError : ERROR_ALREADY_EXISTS);
            break;
        }
        const auto setter = heldRootSetInformation();
        if (!setter) { failed("primitive typed resolver", ERROR_PROC_NOT_FOUND); break; }
        fileCreated = openRelative(directory.value, L".pending-control", stagingAccess, FILE_CREATE, false,
            const_cast<SECURITY_DESCRIPTOR *>(&security.descriptor), file, detail, test.stagingShare);
        if (!fileCreated || !registryFile(file.value, security, false, detail) ||
            !controlIdentity(file.value, fileIdentity)) {
            std::printf("primitive-error phase=%s operation=staging detail=%s\n", phase, detail.c_str());
            ++failures;
            break;
        }
        DWORD written = 0;
        if (!WriteFile(file.value, payload.data(), static_cast<DWORD>(payload.size()), &written, nullptr)) {
            failed("primitive WriteFile", GetLastError());
            break;
        }
        if (written != payload.size()) { failed("primitive short write", ERROR_WRITE_FAULT); break; }
        if (test.sealBefore && !registryReadOnly(file.value, true, detail)) {
            std::printf("primitive-error phase=%s operation=readonly-before detail=%s\n", phase, detail.c_str());
            ++failures;
            break;
        }
        if (!FlushFileBuffers(file.value)) { failed("primitive precommit flush", GetLastError()); break; }
        if (
            !controlBytes(directory.value, L".pending-control", payload, fileIdentity, security, test.sealBefore) ||
            !verifyPrivate(heldHistory.value, security, detail) || !verifyPrivate(directory.value, security, detail) ||
            !controlIdentity(directory.value, current) || !sameControlIdentity(directoryIdentity, current)) {
            std::printf("primitive-error phase=%s operation=precommit detail=%s\n", phase, detail.c_str());
            ++failures;
            break;
        }
        alignas(RegistryRenameInformationV2) std::array<BYTE, 512> storage{};
        auto *rename = reinterpret_cast<RegistryRenameInformationV2 *>(storage.data());
        const std::wstring leaf = L"registry.jloc";
        rename->ReplaceIfExists = FALSE;
        rename->RootDirectory = directory.value;
        rename->FileNameLength = static_cast<ULONG>(leaf.size() * sizeof(wchar_t));
        std::memcpy(rename->FileName, leaf.data(), rename->FileNameLength);
        const ULONG bytes = static_cast<ULONG>(std::max(sizeof(*rename),
            offsetof(RegistryRenameInformationV2, FileName) + rename->FileNameLength));
        IO_STATUS_BLOCK io{};
        const NTSTATUS status = setter(file.value, &io, rename, bytes, heldRootRenameInformationClass);
        published = status >= 0;
        admitted = true;
        std::printf("primitive-result phase=%s status=%08lx mapped=%lu published=%u noReplacement=1\n",
                    phase, static_cast<unsigned long>(status), RtlNtStatusToDosError(status),
                    static_cast<unsigned>(published));
        if (published) {
            bool sealed = test.sealBefore || registryReadOnly(file.value, true, detail);
            if (!sealed) {
                std::printf("primitive-error phase=%s operation=readonly-after detail=%s\n", phase, detail.c_str());
                ++failures;
            }
            if (!FlushFileBuffers(file.value)) { failed("primitive postcommit flush", GetLastError()); sealed = false; }
            if (!sealed || !controlBytes(directory.value, leaf, payload, fileIdentity, security, true)) {
                failed("primitive postpublication verification", ERROR_INVALID_DATA);
            }
        } else {
            if (static_cast<ULONG>(status) != 0xc0000043u) {
                failed("primitive unexpected rename status", RtlNtStatusToDosError(status));
            }
            if (GetFileAttributesW(target.c_str()) != INVALID_FILE_ATTRIBUTES || GetLastError() != ERROR_FILE_NOT_FOUND) {
                failed("primitive failed rename target absence", ERROR_INVALID_DATA);
            }
        }
        if (!controlIdentity(directory.value, current) || !sameControlIdentity(directoryIdentity, current) ||
            !verifyPrivate(directory.value, security, detail) || !verifyPrivate(heldHistory.value, security, detail)) {
            failed("primitive final directory identity/private ACL", ERROR_INVALID_DATA);
        }
    } while (false);
    if (!published && file.value && file.value != INVALID_HANDLE_VALUE) {
        FILE_DISPOSITION_INFO disposition{TRUE};
        const bool cleaned = registryReadOnly(file.value, false, detail) &&
            SetFileInformationByHandle(file.value, FileDispositionInfo, &disposition, sizeof(disposition));
        std::printf("primitive-unpublished-cleanup phase=%s markedOwnedHandle=%u detail=%s\n",
                    phase, static_cast<unsigned>(cleaned), detail.c_str());
        if (!cleaned) failed("primitive owned unpublished disposition", GetLastError());
    }
    controlClose(file, "staging");
    if (fileCreated && !published) {
        const std::wstring pending = history + L"\\.recording-locations\\.pending-control";
        const DWORD attributes = GetFileAttributesW(pending.c_str());
        const DWORD errorCode = GetLastError();
        const bool absent = attributes == INVALID_FILE_ATTRIBUTES && errorCode == ERROR_FILE_NOT_FOUND;
        std::printf("primitive-unpublished-cleanup phase=%s ownedLeafAbsentAfterClose=%u\n",
                    phase, static_cast<unsigned>(absent));
        if (!absent) failed("primitive unpublished owned leaf retained", ERROR_INVALID_DATA);
    }
    controlClose(directory, "destination");
    controlClose(heldHistory, "history");
    for (auto item = parents.rbegin(); item != parents.rend(); ++item) controlClose(**item, "ancestor");
    std::printf("primitive-complete phase=%s renameReached=%u published=%u freshRootRetained=1\n",
                phase, static_cast<unsigned>(admitted), static_cast<unsigned>(published));
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
    // These fresh primitive observations never change a production baseline handle or argument.
    constexpr PrimitiveCase controls[] = {
        {"baseline", true, FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_SHARE_READ, true},
        {"directory-no-delete", false, FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_SHARE_READ, true},
        {"directory-share-delete", true, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_SHARE_READ, true},
        {"staging-share-delete", true, FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE, true},
        {"seal-after-rename", true, FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_SHARE_READ, false}
    };
    for (bool legacyTuple : {false, true}) {
        for (const auto &control : controls) primitive(base, control, legacyTuple, security);
    }
    phase = "complete";
    std::printf("diagnostic-failures=%u syntheticRootsRetained=1\n", failures);
    return failures ? 2 : 0;
}
