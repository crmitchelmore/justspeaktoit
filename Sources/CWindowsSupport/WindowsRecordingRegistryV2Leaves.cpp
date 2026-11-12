// Leaves of the immutable recording namespace (v2): held-root renames that
// publish a byte-exact file, exact reads and the bounded name listing.
#include "WindowsRecordingRegistryV2Internal.hpp"

using namespace jsti_file_security;
using namespace jsti::registryV2;

namespace {
// The user-mode Windows SDK omits this classic NT rename payload/class.
// Keep its ABI private: publication still targets the held directory handle.
struct RegistryRenameInformationV2 {
    BOOLEAN ReplaceIfExists;
    HANDLE RootDirectory;
    ULONG FileNameLength;
    WCHAR FileName[1];
};
static_assert(sizeof(BOOLEAN) == 1 && sizeof(ULONG) == 4 && sizeof(WCHAR) == 2);
static_assert(sizeof(HANDLE) == 4 || sizeof(HANDLE) == 8);
static_assert(alignof(RegistryRenameInformationV2) == alignof(HANDLE));
// Clang's builtin stays constant-evaluable when UCRT offsetof expands to reinterpret_cast.
static_assert(__builtin_offsetof(RegistryRenameInformationV2, ReplaceIfExists) == 0);
static_assert(__builtin_offsetof(RegistryRenameInformationV2, RootDirectory) == sizeof(HANDLE));
static_assert(__builtin_offsetof(RegistryRenameInformationV2, FileNameLength) == 2 * sizeof(HANDLE));
static_assert(__builtin_offsetof(RegistryRenameInformationV2, FileName) == 2 * sizeof(HANDLE) + sizeof(ULONG));
static_assert(sizeof(RegistryRenameInformationV2) == (sizeof(HANDLE) == 8 ? 24 : 16));

bool registryLeaf(const uint8_t *bytes, size_t count, std::wstring &result, JSTIRegistryOutcomeV2 &outcome) {
    std::string encoded, detail;
    if (!registryInput(bytes, count, JSTI_REGISTRY_MAX_LEAF_NAME_BYTES_V2, encoded, outcome)) return false;
    if (!registryName(encoded.c_str(), result, detail)) {
        registryContract(outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
        return false;
    }
    return true;
}

bool registryExact(JSTIRecordingRegistryV2 &registry, size_t file, const uint8_t *expected, size_t count,
                   JSTIRegistryOutcomeV2 &outcome) {
    LARGE_INTEGER size{}, zero{};
    if (!GetFileSizeEx(registry.resources[file].value, &size) ||
        !SetFilePointerEx(registry.resources[file].value, zero, nullptr, FILE_BEGIN)) {
        registryCause(outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(),
                      JSTI_REGISTRY_STAGE_FENCE_CONTENT_V2, registry.resources[file].id);
        return false;
    }
    if (size.QuadPart != static_cast<LONGLONG>(count)) {
        registryContract(outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_CONTENT_V2);
        return false;
    }
    std::array<uint8_t, JSTI_REGISTRY_MAX_LEAF_BYTES_V2> bytes{};
    size_t offset = 0;
    while (offset < count) {
        DWORD received = 0;
        if (!ReadFile(registry.resources[file].value, bytes.data() + offset,
                      static_cast<DWORD>(count - offset), &received, nullptr)) {
            registryCause(outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(),
                          JSTI_REGISTRY_STAGE_FENCE_CONTENT_V2, registry.resources[file].id);
            return false;
        }
        if (!received) break;
        offset += received;
    }
    if (offset != count || std::memcmp(bytes.data(), expected, count)) {
        registryContract(outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_CONTENT_V2);
        return false;
    }
    if (!GetFileSizeEx(registry.resources[file].value, &size)) {
        registryCause(outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(),
                      JSTI_REGISTRY_STAGE_FENCE_CONTENT_V2, registry.resources[file].id);
        return false;
    }
    if (size.QuadPart != static_cast<LONGLONG>(count)) {
        registryContract(outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_CONTENT_V2);
        return false;
    }
    return true;
}

bool registryCancelled(jsti_registry_cancelled_v2_fn callback, void *context, uint32_t checkpoint,
                       JSTIRegistryOutcomeV2 &outcome) {
    if (!callback || !callback(context, checkpoint)) return false;
    registryContract(outcome, JSTI_REGISTRY_CONTRACT_CANCELLED_V2,
        checkpoint == JSTI_REGISTRY_CHECK_POSTCOMMIT_V2 ? JSTI_REGISTRY_STAGE_POSTCOMMIT_V2 :
        (checkpoint == JSTI_REGISTRY_CHECK_PRECOMMIT_V2 ? JSTI_REGISTRY_STAGE_PRECOMMIT_V2 :
         JSTI_REGISTRY_STAGE_ADMISSION_V2));
    return true;
}
} // namespace

int jsti_recording_registry_append_v2(JSTIRecordingRegistryV2 *registry, const uint8_t *name, size_t nameCount,
                                     const uint8_t *bytes, size_t count, jsti_registry_cancelled_v2_fn cancelled,
                                     void *context, JSTIRegistryOutcomeV2 *outcome) {
    if (!registryOutcome(outcome)) return -1;
    RegistryCallV2 call(registry, *outcome);
    if (!call.admitted) return -1;
    size_t file = registry->resources.size(), named = registry->resources.size();
    try {
        std::wstring leaf;
        if (!bytes || !count || count > JSTI_REGISTRY_MAX_LEAF_BYTES_V2) {
            registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
        } else if (registryLeaf(name, nameCount, leaf, *outcome) && registry->validate(*outcome)) {
            const auto setInformation = heldRootSetInformation();
            if (!setInformation) {
                registryCause(*outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, ERROR_PROC_NOT_FOUND,
                              JSTI_REGISTRY_STAGE_PUBLISH_V2);
                return -1;
            }
            std::array<uint8_t, JSTI_REGISTRY_MAX_LEAF_BYTES_V2> payload{};
            std::memcpy(payload.data(), bytes, count);
            GUID guid{};
            wchar_t identifier[40]{};
            const HRESULT allocated = CoCreateGuid(&guid);
            if (FAILED(allocated)) registryCause(*outcome, JSTI_REGISTRY_DOMAIN_HRESULT_V2,
                static_cast<uint32_t>(allocated), JSTI_REGISTRY_STAGE_OPEN_V2);
            else if (!StringFromGUID2(guid, identifier, 40)) registryContract(*outcome,
                JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_OPEN_V2);
            const std::wstring pending = L".pending-" + std::wstring(identifier + 1, 36);
            alignas(RegistryRenameInformationV2) std::array<BYTE, 512> renameBytes{};
            auto *rename = reinterpret_cast<RegistryRenameInformationV2 *>(renameBytes.data());
            rename->ReplaceIfExists = FALSE;
            // The pending handle was created in the held namespace. Keep the
            // same-directory contract above, including its no-delete-share fence.
            rename->RootDirectory = nullptr;
            rename->FileNameLength = static_cast<ULONG>(leaf.size() * sizeof(wchar_t));
            std::memcpy(rename->FileName, leaf.data(), rename->FileNameLength);
            const ULONG renameSize = static_cast<ULONG>(std::max(sizeof(*rename),
                offsetof(RegistryRenameInformationV2, FileName) + rename->FileNameLength));
            if (!outcome->cause_count && !registryCancelled(cancelled, context,
                JSTI_REGISTRY_CHECK_ADMISSION_V2, *outcome) && registry->openRelativeV2(
                registry->directory, pending,
                FILE_READ_DATA | FILE_WRITE_DATA | FILE_WRITE_ATTRIBUTES | FILE_READ_ATTRIBUTES | READ_CONTROL | DELETE,
                FILE_CREATE, false, &registry->security.descriptor, FILE_SHARE_READ, file, *outcome)) {
                if (registry->permissions(file, true, *outcome)) {
                    for (size_t offset = 0; offset < count;) {
                        DWORD written = 0;
                        if (!WriteFile(registry->resources[file].value, payload.data() + offset,
                            static_cast<DWORD>(count - offset), &written, nullptr)) {
                            registryCause(*outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(),
                                          JSTI_REGISTRY_STAGE_WRITE_V2, registry->resources[file].id);
                            break;
                        }
                        if (!written) {
                            registryContract(*outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_WRITE_V2);
                            break;
                        }
                        offset += written;
                    }
                }
                FILE_BASIC_INFO attributes{};
                if (!outcome->cause_count) {
                    if (!GetFileInformationByHandleEx(registry->resources[file].value, FileBasicInfo,
                                                     &attributes, sizeof(attributes))) {
                        registryCause(*outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(),
                                      JSTI_REGISTRY_STAGE_READONLY_V2);
                    } else {
                        attributes.FileAttributes |= FILE_ATTRIBUTE_READONLY;
                        if (!SetFileInformationByHandle(registry->resources[file].value, FileBasicInfo,
                                                        &attributes, sizeof(attributes))) {
                            registryCause(*outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(),
                                          JSTI_REGISTRY_STAGE_READONLY_V2);
                        }
                    }
                }
                if (!outcome->cause_count && !FlushFileBuffers(registry->resources[file].value)) {
                    registryCause(*outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(), JSTI_REGISTRY_STAGE_FLUSH_V2);
                }
                if (!outcome->cause_count) {
                    if (registry->attributes(file, false, true, *outcome)) {
                        registryExact(*registry, file, payload.data(), count, *outcome);
                    }
                    if (!registry->poisoned) registry->validate(*outcome);
                }
                if (!outcome->cause_count && !registryCancelled(cancelled, context,
                    JSTI_REGISTRY_CHECK_PRECOMMIT_V2, *outcome)) {
                    IO_STATUS_BLOCK status{};
                    const NTSTATUS code = setInformation(registry->resources[file].value, &status,
                        rename, renameSize, heldRootRenameInformationClass);
                    if (code < 0) registryCause(*outcome, JSTI_REGISTRY_DOMAIN_NTSTATUS_V2,
                        static_cast<uint32_t>(code), JSTI_REGISTRY_STAGE_PUBLISH_V2);
                    else outcome->effect = JSTI_REGISTRY_EFFECT_PUBLISHED_V2;
                }
                if (outcome->effect == JSTI_REGISTRY_EFFECT_PUBLISHED_V2) {
                    if (!FlushFileBuffers(registry->resources[file].value)) registryCause(*outcome,
                        JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(), JSTI_REGISTRY_STAGE_FLUSH_V2);
                    registryCancelled(cancelled, context, JSTI_REGISTRY_CHECK_POSTCOMMIT_V2, *outcome);
                    const bool ancestry = registry->validate(*outcome);
                    const bool held = !registry->poisoned && registry->attributes(file, false, true, *outcome) &&
                        registry->permissions(file, true, *outcome);
                    if (held) {
                        JSTIRegistryIdentityV2 current{};
                        if (registry->identity(file, current, *outcome) &&
                            !registrySame(current, registry->resources[file].identity)) registryContract(*outcome,
                                JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_IDENTITY_V2);
                        registryExact(*registry, file, payload.data(), count, *outcome);
                    }
                    if (ancestry && held && !registry->poisoned && registry->openRelativeV2(
                        registry->directory, leaf, FILE_READ_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL,
                        FILE_OPEN, false, nullptr, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        named, *outcome)) {
                        if (!registrySame(registry->resources[file].identity, registry->resources[named].identity)) {
                            registryContract(*outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2,
                                             JSTI_REGISTRY_STAGE_FENCE_IDENTITY_V2);
                        } else if (registry->attributes(named, false, true, *outcome) &&
                                   registry->permissions(named, true, *outcome)) {
                            registryExact(*registry, named, payload.data(), count, *outcome);
                            JSTIRegistryIdentityV2 current{};
                            if (registry->identity(named, current, *outcome) &&
                                !registrySame(current, registry->resources[file].identity)) registryContract(*outcome,
                                    JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_IDENTITY_V2);
                            registry->attributes(named, false, true, *outcome);
                        }
                    }
                    if (!registry->poisoned) {
                        registry->validate(*outcome);
                        if (!registry->poisoned && registry->attributes(file, false, true, *outcome) &&
                            registry->permissions(file, true, *outcome)) {
                            JSTIRegistryIdentityV2 current{};
                            if (registry->identity(file, current, *outcome) &&
                                !registrySame(current, registry->resources[file].identity)) registryContract(*outcome,
                                    JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_IDENTITY_V2);
                        }
                    }
                }
            }
        }
    } catch (const std::exception &) {
        registryContract(*outcome, JSTI_REGISTRY_CONTRACT_ALLOCATION_V2, JSTI_REGISTRY_STAGE_WRITE_V2);
    }
    if (named < registry->resources.size()) registry->release(named, *outcome);
    if (file < registry->resources.size() && registry->resources[file].value) {
        if (outcome->effect != JSTI_REGISTRY_EFFECT_PUBLISHED_V2 && !registry->poisoned) {
            FILE_BASIC_INFO attributes{};
            if (!GetFileInformationByHandleEx(registry->resources[file].value, FileBasicInfo, &attributes,
                                             sizeof(attributes))) registryCause(*outcome,
                JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(), JSTI_REGISTRY_STAGE_DISCARD_V2,
                registry->resources[file].id, true);
            else {
                attributes.FileAttributes &= ~FILE_ATTRIBUTE_READONLY;
                if (!SetFileInformationByHandle(registry->resources[file].value, FileBasicInfo,
                                                &attributes, sizeof(attributes))) registryCause(*outcome,
                    JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(), JSTI_REGISTRY_STAGE_DISCARD_V2,
                    registry->resources[file].id, true);
                else {
                    FILE_DISPOSITION_INFO disposition{TRUE};
                    if (!SetFileInformationByHandle(registry->resources[file].value, FileDispositionInfo,
                                                    &disposition, sizeof(disposition))) registryCause(*outcome,
                        JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(), JSTI_REGISTRY_STAGE_DISCARD_V2,
                        registry->resources[file].id, true);
                }
            }
        }
        registry->release(file, *outcome);
    }
    return outcome->cause_count ? -1 : 0;
}

int jsti_recording_registry_read_v2(JSTIRecordingRegistryV2 *registry, const uint8_t *name, size_t nameCount,
                                   uint8_t *bytes, size_t capacity, size_t *written, JSTIRegistryOutcomeV2 *outcome) {
    if (!registryOutcome(outcome)) return -1;
    RegistryCallV2 call(registry, *outcome);
    if (!call.admitted) return -1;
    if (written) *written = 0;
    size_t file = registry->resources.size();
    size_t offset = 0;
    try {
        std::wstring leaf;
        if (!bytes || !written || !capacity || capacity > JSTI_REGISTRY_MAX_LEAF_BYTES_V2) {
            registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
        } else if (registryLeaf(name, nameCount, leaf, *outcome) && registry->validate(*outcome) &&
            registry->openRelativeV2(registry->directory, leaf, FILE_READ_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL,
                FILE_OPEN, false, nullptr, FILE_SHARE_READ, file, *outcome) &&
            registry->attributes(file, false, true, *outcome) && registry->permissions(file, true, *outcome)) {
            LARGE_INTEGER size{};
            if (!GetFileSizeEx(registry->resources[file].value, &size)) registryCause(*outcome,
                JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(), JSTI_REGISTRY_STAGE_READ_V2);
            else if (size.QuadPart <= 0 || static_cast<ULONGLONG>(size.QuadPart) > capacity) {
                registryContract(*outcome, JSTI_REGISTRY_CONTRACT_BUDGET_V2, JSTI_REGISTRY_STAGE_READ_V2);
            } else {
                while (offset < static_cast<size_t>(size.QuadPart)) {
                    DWORD received = 0;
                    if (!ReadFile(registry->resources[file].value, bytes + offset,
                                  static_cast<DWORD>(size.QuadPart - offset), &received, nullptr)) {
                        registryCause(*outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(), JSTI_REGISTRY_STAGE_READ_V2);
                        break;
                    }
                    if (!received) { registryContract(*outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2,
                                                     JSTI_REGISTRY_STAGE_READ_V2); break; }
                    offset += received;
                }
                if (!outcome->cause_count) {
                    registryExact(*registry, file, bytes, offset, *outcome);
                    registry->attributes(file, false, true, *outcome);
                    registry->permissions(file, true, *outcome);
                    registry->validate(*outcome);
                }
            }
        }
    } catch (const std::exception &) {
        registryContract(*outcome, JSTI_REGISTRY_CONTRACT_ALLOCATION_V2, JSTI_REGISTRY_STAGE_READ_V2);
    }
    if (file < registry->resources.size()) registry->release(file, *outcome);
    if (!outcome->cause_count) *written = offset;
    return outcome->cause_count ? -1 : 0;
}

int jsti_recording_registry_names_v2(JSTIRecordingRegistryV2 *registry, uint8_t *names, size_t capacity,
                                    size_t *written, uint32_t *count, JSTIRegistryOutcomeV2 *outcome) {
    if (!registryOutcome(outcome)) return -1;
    RegistryCallV2 call(registry, *outcome);
    if (!call.admitted) return -1;
    if (written) *written = 0;
    if (count) *count = 0;
    try {
        if (!names || !written || !count || !capacity || capacity > JSTI_REGISTRY_MAX_NAMES_BYTES_V2) {
            registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
            return -1;
        }
        if (!registry->validate(*outcome)) return -1;
        alignas(FILE_ID_BOTH_DIR_INFO) std::array<BYTE, 16 * 1024> buffer{};
        size_t used = 0;
        uint32_t entries = 0;
        bool first = true;
        while (true) {
            if (!GetFileInformationByHandleEx(registry->resources[registry->directory].value,
                first ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo, buffer.data(),
                static_cast<DWORD>(buffer.size()))) {
                const DWORD code = GetLastError();
                if (code == ERROR_NO_MORE_FILES) break;
                registryCause(*outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, code, JSTI_REGISTRY_STAGE_ENUMERATE_V2);
                return -1;
            }
            first = false;
            size_t offset = 0;
            while (true) {
                const size_t header = offsetof(FILE_ID_BOTH_DIR_INFO, FileName);
                if (offset > buffer.size() - header) {
                    registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ENUMERATE_V2);
                    return -1;
                }
                auto *entry = reinterpret_cast<FILE_ID_BOTH_DIR_INFO *>(buffer.data() + offset);
                if (entry->FileNameLength % sizeof(wchar_t) ||
                    entry->FileNameLength > buffer.size() - offset - header) {
                    registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ENUMERATE_V2);
                    return -1;
                }
                const std::wstring name(entry->FileName, entry->FileNameLength / sizeof(wchar_t));
                if (name != L"." && name != L"..") {
                    const std::string encoded = jsti::utf8(name);
                    std::wstring verified;
                    std::string detail;
                    if (!registryName(encoded.c_str(), verified, detail) ||
                        (entry->FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
                        registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ENUMERATE_V2);
                        return -1;
                    }
                    if (++entries > JSTI_REGISTRY_MAX_NAMES_V2 || encoded.size() + 1 > capacity - used) {
                        registryContract(*outcome, JSTI_REGISTRY_CONTRACT_BUDGET_V2, JSTI_REGISTRY_STAGE_ENUMERATE_V2);
                        return -1;
                    }
                    std::memcpy(names + used, encoded.c_str(), encoded.size() + 1);
                    used += encoded.size() + 1;
                }
                if (!entry->NextEntryOffset) break;
                if (entry->NextEntryOffset < header || entry->NextEntryOffset > buffer.size() - offset) {
                    registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ENUMERATE_V2);
                    return -1;
                }
                offset += entry->NextEntryOffset;
            }
        }
        if (registry->validate(*outcome)) { *written = used; *count = entries; }
    } catch (const std::exception &) {
        registryContract(*outcome, JSTI_REGISTRY_CONTRACT_ALLOCATION_V2, JSTI_REGISTRY_STAGE_ENUMERATE_V2);
    }
    return outcome->cause_count ? -1 : 0;
}
