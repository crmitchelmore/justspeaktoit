// The immutable recording namespace (v2): typed outcomes, held-root renames and byte-exact leaves.
#include "WindowsFileSecurityInternal.hpp"

using namespace jsti_file_security;

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

bool registryOutcome(JSTIRegistryOutcomeV2 *outcome) {
    static_assert(__builtin_offsetof(JSTIRegistryOutcomeV2, abi_version) == 0);
    static_assert(__builtin_offsetof(JSTIRegistryOutcomeV2, struct_size) == sizeof(uint32_t));
    if (!outcome) return false;
    uint32_t header[2]{};
    std::memcpy(header, outcome, sizeof(header));
    if (header[0] != JSTI_REGISTRY_ABI_V2 || header[1] < sizeof(*outcome)) return false;
    *outcome = {};
    outcome->abi_version = JSTI_REGISTRY_ABI_V2;
    outcome->struct_size = sizeof(*outcome);
    outcome->primary_index = UINT32_MAX;
    return true;
}

void registryCause(JSTIRegistryOutcomeV2 &outcome, uint32_t domain, uint32_t code, uint32_t stage,
                   uint64_t resource = 0, bool cleanup = false) {
    // At most 32 operation/fence failures and at most 256
    // resource releases. No loop appends per byte/name or retries a release.
    if (outcome.cause_count == JSTI_REGISTRY_MAX_CAUSES_V2) std::terminate();
    const uint32_t index = outcome.cause_count++;
    outcome.causes[index] = {static_cast<uint32_t>(cleanup ? JSTI_REGISTRY_CAUSE_CLEANUP_V2 :
        (index ? JSTI_REGISTRY_CAUSE_SECONDARY_V2 : JSTI_REGISTRY_CAUSE_PRIMARY_V2)),
        domain, code, stage, resource};
    if (!index) outcome.primary_index = 0;
    if (cleanup) ++outcome.cleanup_count;
}

void registryContract(JSTIRegistryOutcomeV2 &outcome, uint32_t code, uint32_t stage) {
    registryCause(outcome, JSTI_REGISTRY_DOMAIN_CONTRACT_V2, code, stage);
}

bool registrySame(const JSTIRegistryIdentityV2 &first, const JSTIRegistryIdentityV2 &second) {
    return first.volume_serial == second.volume_serial && !std::memcmp(first.file_id, second.file_id, 16);
}

struct RegistryResourceV2 {
    HANDLE value = nullptr;
    uint64_t id = 0;
    bool localMemory = false;
    JSTIRegistryIdentityV2 identity{};
};
} // namespace

struct JSTIRecordingRegistryV2 {
    PrivateSecurity security;
    std::array<RegistryResourceV2, JSTI_REGISTRY_MAX_RESOURCES_V2> resources{};
    std::vector<std::wstring> components;
    std::vector<size_t> parents;
    const std::wstring namespaceName = L".recording-locations";
    size_t directory = 0;
    uint64_t nextID = 1;
    bool active = false, closed = false, poisoned = false;
    JSTIRegistryOutcomeV2 closeOutcome{};
    JSTIRegistryOutcomeV2 poisonOutcome{};

    ~JSTIRecordingRegistryV2() { security.acl.value = nullptr; }

    size_t reserve(JSTIRegistryOutcomeV2 &outcome) {
        for (size_t index = 0; index < resources.size(); ++index) {
            if (!resources[index].value) return index;
        }
        registryContract(outcome, JSTI_REGISTRY_CONTRACT_BUDGET_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
        return resources.size();
    }

    void acquire(size_t index, HANDLE value, bool local = false) {
        resources[index] = {value, nextID++, local, {}};
    }

    void release(size_t index, JSTIRegistryOutcomeV2 &outcome) {
        auto &resource = resources[index];
        if (!resource.value) return;
        const HANDLE value = resource.value;
        resource.value = nullptr;
        if (value == security.acl.value) security.acl.value = nullptr;
        bool success;
        if (resource.localMemory) success = LocalFree(value) == nullptr;
        else {
            ++outcome.close_attempt_count;
            success = CloseHandle(value) != FALSE;
        }
        if (!success) {
            const DWORD code = GetLastError();
            registryCause(outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, code,
                          JSTI_REGISTRY_STAGE_CLOSE_V2, resource.id, true);
            ++outcome.release_unconfirmed_count;
            outcome.capability_poisoned = 1;
            poisoned = true;
            poisonOutcome = outcome;
        }
    }

    void releaseAll(JSTIRegistryOutcomeV2 &outcome) {
        for (size_t index = resources.size(); index > 0; --index) release(index - 1, outcome);
    }

    bool identity(size_t index, JSTIRegistryIdentityV2 &result, JSTIRegistryOutcomeV2 &outcome,
                  uint32_t stage = JSTI_REGISTRY_STAGE_IDENTITY_V2) {
        FILE_ID_INFO native{};
        if (!GetFileInformationByHandleEx(resources[index].value, FileIdInfo, &native, sizeof(native))) {
            registryCause(outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(), stage, resources[index].id);
            return false;
        }
        if (std::all_of(std::begin(native.FileId.Identifier), std::end(native.FileId.Identifier),
                        [](BYTE value) { return value == 0; })) {
            registryContract(outcome, JSTI_REGISTRY_CONTRACT_IDENTITY_V2, stage);
            return false;
        }
        result.volume_serial = native.VolumeSerialNumber;
        std::memcpy(result.file_id, native.FileId.Identifier, 16);
        return true;
    }

    bool attributes(size_t index, bool directoryExpected, bool immutable, JSTIRegistryOutcomeV2 &outcome) {
        FILE_ATTRIBUTE_TAG_INFO attributes{};
        BY_HANDLE_FILE_INFORMATION information{};
        if (!GetFileInformationByHandleEx(resources[index].value, FileAttributeTagInfo, &attributes,
                                         sizeof(attributes)) ||
            !GetFileInformationByHandle(resources[index].value, &information)) {
            registryCause(outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(),
                          JSTI_REGISTRY_STAGE_FENCE_ATTRIBUTES_V2, resources[index].id);
            return false;
        }
        if ((attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
            bool(attributes.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != directoryExpected ||
            (immutable && !(attributes.FileAttributes & FILE_ATTRIBUTE_READONLY)) ||
            (!directoryExpected && GetFileType(resources[index].value) != FILE_TYPE_DISK)) {
            registryContract(outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_ATTRIBUTES_V2);
            return false;
        }
        if (!directoryExpected && information.nNumberOfLinks != 1) {
            registryContract(outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_LINKS_V2);
            return false;
        }
        return true;
    }

    bool permissions(size_t index, bool privateExpected, JSTIRegistryOutcomeV2 &outcome) {
        const size_t memory = reserve(outcome);
        if (memory == resources.size()) return false;
        PSID owner = nullptr;
        PACL acl = nullptr;
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        const DWORD code = GetSecurityInfo(resources[index].value, SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | (privateExpected ? DACL_SECURITY_INFORMATION : 0),
            &owner, nullptr, &acl, nullptr, &descriptor);
        if (descriptor) acquire(memory, descriptor, true);
        bool success = code == ERROR_SUCCESS;
        if (!success) {
            registryCause(outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, code,
                          JSTI_REGISTRY_STAGE_FENCE_ACL_V2, resources[index].id);
        } else {
            DWORD nativeError = 0;
            const bool valid = privateExpected ?
                privateDescriptorCheck(owner, acl, descriptor, security, nativeError) == PrivateDescriptorCheck::valid :
                owner && EqualSid(owner, security.userSID());
            if (!valid) {
                if (nativeError) registryCause(outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, nativeError,
                                              JSTI_REGISTRY_STAGE_FENCE_ACL_V2, resources[index].id);
                else registryContract(outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_ACL_V2);
                success = false;
            }
        }
        release(memory, outcome);
        return success && !poisoned;
    }

    bool openRelativeV2(size_t parent, const std::wstring &name, ACCESS_MASK access, ULONG disposition,
                        bool directoryExpected, PSECURITY_DESCRIPTOR descriptor, ULONG sharing,
                        size_t &result, JSTIRegistryOutcomeV2 &outcome) {
        result = reserve(outcome);
        if (result == resources.size()) return false;
        UNICODE_STRING unicode{};
        unicode.Buffer = const_cast<PWSTR>(name.c_str());
        unicode.Length = static_cast<USHORT>(name.size() * sizeof(wchar_t));
        unicode.MaximumLength = unicode.Length;
        OBJECT_ATTRIBUTES attributes{};
        attributes.Length = sizeof(attributes);
        attributes.RootDirectory = resources[parent].value;
        attributes.ObjectName = &unicode;
        attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
        attributes.SecurityDescriptor = descriptor;
        IO_STATUS_BLOCK status{};
        HANDLE handle = nullptr;
        const NTSTATUS code = NtCreateFile(&handle, access | SYNCHRONIZE, &attributes, &status, nullptr,
            FILE_ATTRIBUTE_NORMAL, sharing, disposition, FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT |
            (directoryExpected ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE), nullptr, 0);
        if (handle && handle != INVALID_HANDLE_VALUE) acquire(result, handle);
        if (code < 0) {
            registryCause(outcome, JSTI_REGISTRY_DOMAIN_NTSTATUS_V2, static_cast<uint32_t>(code),
                          JSTI_REGISTRY_STAGE_OPEN_V2);
            return false;
        }
        return attributesCheckAndCapture(result, directoryExpected, outcome);
    }

    bool attributesCheckAndCapture(size_t index, bool directoryExpected, JSTIRegistryOutcomeV2 &outcome) {
        return attributes(index, directoryExpected, false, outcome) &&
            identity(index, resources[index].identity, outcome);
    }

    bool validate(JSTIRegistryOutcomeV2 &outcome) {
        if (closed || poisoned) {
            registryContract(outcome, closed ? JSTI_REGISTRY_CONTRACT_CLOSED_V2 :
                             JSTI_REGISTRY_CONTRACT_TEARDOWN_UNCONFIRMED_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
            return false;
        }
        for (size_t index : parents) {
            const uint32_t before = outcome.cause_count;
            JSTIRegistryIdentityV2 current{};
            if (!attributes(index, true, false, outcome) || !identity(index, current, outcome) ||
                !registrySame(current, resources[index].identity)) {
                if (outcome.cause_count == before) registryContract(outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2,
                                                          JSTI_REGISTRY_STAGE_FENCE_ANCESTRY_V2);
                return false;
            }
        }
        const uint32_t before = outcome.cause_count;
        JSTIRegistryIdentityV2 current{};
        if (!attributes(directory, true, false, outcome) || !identity(directory, current, outcome) ||
            !registrySame(current, resources[directory].identity)) {
            if (outcome.cause_count == before) registryContract(outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2,
                                                      JSTI_REGISTRY_STAGE_FENCE_ANCESTRY_V2);
            return false;
        }
        size_t probe = reserve(outcome);
        if (probe == resources.size()) return false;
        HANDLE root = CreateFileW(components.front().c_str(),
            FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (root == INVALID_HANDLE_VALUE) {
            registryCause(outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(), JSTI_REGISTRY_STAGE_FENCE_ANCESTRY_V2);
            return false;
        }
        acquire(probe, root);
        bool matched = attributesCheckAndCapture(probe, true, outcome);
        if (matched && !registrySame(resources[probe].identity, resources[parents.front()].identity)) {
            registryContract(outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_ANCESTRY_V2);
            matched = false;
        }
        release(probe, outcome);
        if (!matched || poisoned) return false;
        for (size_t part = 1; part <= parents.size(); ++part) {
            const bool namespacePart = part == parents.size();
            const size_t expected = namespacePart ? directory : parents[part];
            const size_t anchor = parents[part - 1];
            const bool opened = openRelativeV2(anchor, namespacePart ? namespaceName : components[part],
                FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL, FILE_OPEN, true, nullptr,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, probe, outcome);
            matched = opened;
            if (opened && !registrySame(resources[probe].identity, resources[expected].identity)) {
                registryContract(outcome, JSTI_REGISTRY_CONTRACT_CHANGED_V2, JSTI_REGISTRY_STAGE_FENCE_ANCESTRY_V2);
                matched = false;
            }
            if (probe < resources.size()) release(probe, outcome);
            if (!matched || poisoned) return false;
        }
        return permissions(parents.back(), false, outcome) && permissions(directory, true, outcome);
    }
};

namespace {
struct RegistryCallV2 {
    JSTIRecordingRegistryV2 *registry;
    JSTIRegistryOutcomeV2 &outcome;
    bool admitted = false;
    RegistryCallV2(JSTIRecordingRegistryV2 *value, JSTIRegistryOutcomeV2 &outcome, bool terminal = false)
        : registry(value), outcome(outcome) {
        if (!value) registryContract(outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
        else if (value->active) registryContract(outcome, JSTI_REGISTRY_CONTRACT_REENTRANT_V2,
                                               JSTI_REGISTRY_STAGE_ADMISSION_V2);
        else if (!terminal && (value->closed || value->poisoned)) {
            registryContract(outcome, value->closed ? JSTI_REGISTRY_CONTRACT_CLOSED_V2 :
                             JSTI_REGISTRY_CONTRACT_TEARDOWN_UNCONFIRMED_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
        } else { value->active = true; admitted = true; }
    }
    ~RegistryCallV2() {
        if (admitted) {
            if (registry->poisoned && !registry->closed) registry->poisonOutcome = outcome;
            registry->active = false;
        }
    }
};

bool registryInput(const uint8_t *bytes, size_t count, size_t maximum, std::string &result,
                   JSTIRegistryOutcomeV2 &outcome) {
    if (!bytes || !count || count > maximum || std::memchr(bytes, 0, count)) {
        registryContract(outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
        return false;
    }
    result.assign(reinterpret_cast<const char *>(bytes), count);
    return true;
}

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

void registryCloseV2(JSTIRecordingRegistryV2 &registry, JSTIRegistryOutcomeV2 &outcome) {
    if (registry.closed) { outcome = registry.closeOutcome; return; }
    registry.closed = true;
    if (registry.poisoned) {
        outcome = registry.poisonOutcome;
    }
    registry.releaseAll(outcome);
    registry.closeOutcome = outcome;
}
} // namespace

int jsti_recording_registry_open_v2(const uint8_t *history, size_t historyCount, int initialize,
                                   JSTIRecordingRegistryV2 **result, JSTIRegistryOutcomeV2 *outcome) {
    if (!registryOutcome(outcome)) return -1;
    if (!result) { registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2,
                                    JSTI_REGISTRY_STAGE_ADMISSION_V2); return -1; }
    *result = nullptr;
    std::unique_ptr<JSTIRecordingRegistryV2> registry;
    try {
        std::string path, detail;
        std::vector<std::wstring> components;
        if ((initialize != 0 && initialize != 1) ||
            !registryInput(history, historyCount, JSTI_REGISTRY_MAX_PATH_UTF8_BYTES_V2, path, *outcome) ||
            !parsePath(path.c_str(), components, detail)) {
            if (!outcome->cause_count) registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2,
                                                       JSTI_REGISTRY_STAGE_ADMISSION_V2);
            return -1;
        }
        // Reserve all ancestry plus directory, ACL, token and transient readers
        // before FILE_CREATE. Slots are fixed; diagnostic storage is caller-owned.
        if (components.size() + 8 > JSTI_REGISTRY_MAX_RESOURCES_V2) {
            registryContract(*outcome, JSTI_REGISTRY_CONTRACT_BUDGET_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
            return -1;
        }
        registry = std::make_unique<JSTIRecordingRegistryV2>();
        registry->components = std::move(components);
        registry->parents.reserve(registry->components.size());
        size_t token = registry->reserve(*outcome);
        HANDLE native = nullptr;
        if (!OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &native)) {
            const DWORD code = GetLastError();
            if (code != ERROR_NO_TOKEN || !OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &native)) {
                registryCause(*outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2,
                              code == ERROR_NO_TOKEN ? GetLastError() : code, JSTI_REGISTRY_STAGE_OPEN_V2);
            }
        }
        if (native) registry->acquire(token, native);
        DWORD securityError = 0;
        if (!outcome->cause_count && !registry->security.initialiseFromToken(native, detail, &securityError, false)) {
            registryCause(*outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2, securityError, JSTI_REGISTRY_STAGE_OPEN_V2);
        }
        if (registry->security.acl.value) {
            registry->acquire(registry->reserve(*outcome), registry->security.acl.value, true);
        }
        registry->release(token, *outcome);
        if (!outcome->cause_count) {
            const size_t drive = registry->reserve(*outcome);
            native = CreateFileW(registry->components.front().c_str(),
                FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL, FILE_SHARE_READ | FILE_SHARE_WRITE,
                nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (native == INVALID_HANDLE_VALUE) registryCause(*outcome, JSTI_REGISTRY_DOMAIN_WIN32_V2,
                GetLastError(), JSTI_REGISTRY_STAGE_OPEN_V2);
            else {
                registry->acquire(drive, native);
                registry->parents.push_back(drive);
                registry->attributesCheckAndCapture(drive, true, *outcome);
                if (!outcome->cause_count) {
                    wchar_t filesystem[64]{};
                    DWORD flags = 0;
                    if (!GetVolumeInformationByHandleW(native, nullptr, 0, nullptr, nullptr, &flags,
                                                      filesystem, 64)) registryCause(*outcome,
                        JSTI_REGISTRY_DOMAIN_WIN32_V2, GetLastError(), JSTI_REGISTRY_STAGE_OPEN_V2);
                    else if (std::wstring(filesystem) != L"NTFS" || !(flags & FILE_PERSISTENT_ACLS)) {
                        registryContract(*outcome, JSTI_REGISTRY_CONTRACT_UNSUPPORTED_V2, JSTI_REGISTRY_STAGE_OPEN_V2);
                    }
                }
            }
            for (size_t part = 1; !outcome->cause_count && part < registry->components.size(); ++part) {
                size_t child;
                if (registry->openRelativeV2(registry->parents.back(), registry->components[part],
                    FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL, FILE_OPEN, true, nullptr,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, child, *outcome)) registry->parents.push_back(child);
            }
            if (!outcome->cause_count && registry->permissions(registry->parents.back(), false, *outcome)) {
                registry->openRelativeV2(registry->parents.back(), registry->namespaceName,
                    READ_CONTROL | DELETE | FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_TRAVERSE | FILE_READ_ATTRIBUTES,
                    initialize ? FILE_CREATE : FILE_OPEN, true,
                    initialize ? &registry->security.descriptor : nullptr, FILE_SHARE_READ | FILE_SHARE_WRITE,
                    registry->directory, *outcome);
            }
            if (!outcome->cause_count) registry->validate(*outcome);
        }
        if (!outcome->cause_count) { *result = registry.release(); return 0; }
    } catch (const std::exception &) {
        registryContract(*outcome, JSTI_REGISTRY_CONTRACT_ALLOCATION_V2, JSTI_REGISTRY_STAGE_OPEN_V2);
    }
    if (registry) {
        if (registry->security.acl.value &&
            std::none_of(registry->resources.begin(), registry->resources.end(),
                         [&](const RegistryResourceV2 &value) { return value.value == registry->security.acl.value; })) {
            registry->acquire(registry->reserve(*outcome), registry->security.acl.value, true);
        }
        registry->releaseAll(*outcome);
    }
    return -1;
}
int jsti_recording_registry_identity_v2(JSTIRecordingRegistryV2 *registry, JSTIRegistryIdentityV2 *history,
                                       JSTIRegistryIdentityV2 *namespaceIdentity, JSTIRegistryOutcomeV2 *outcome) {
    if (!registryOutcome(outcome)) return -1;
    RegistryCallV2 call(registry, *outcome);
    if (!call.admitted) return -1;
    if (!history || !namespaceIdentity) registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2,
                                                        JSTI_REGISTRY_STAGE_ADMISSION_V2);
    else if (registry->validate(*outcome)) {
        *history = registry->resources[registry->parents.back()].identity;
        *namespaceIdentity = registry->resources[registry->directory].identity;
    }
    return outcome->cause_count ? -1 : 0;
}

int jsti_recording_registry_validate_v2(JSTIRecordingRegistryV2 *registry, JSTIRegistryOutcomeV2 *outcome) {
    if (!registryOutcome(outcome)) return -1;
    RegistryCallV2 call(registry, *outcome);
    if (!call.admitted) return -1;
    registry->validate(*outcome);
    return outcome->cause_count ? -1 : 0;
}

int jsti_recording_registry_close_v2(JSTIRecordingRegistryV2 *registry, JSTIRegistryOutcomeV2 *outcome) {
    if (!registryOutcome(outcome)) return -1;
    RegistryCallV2 call(registry, *outcome, true);
    if (!call.admitted) return -1;
    registryCloseV2(*registry, *outcome);
    return outcome->cause_count ? -1 : 0;
}

int jsti_recording_registry_destroy_v2(JSTIRecordingRegistryV2 **registry, JSTIRegistryOutcomeV2 *outcome) {
    if (!registryOutcome(outcome)) return -1;
    if (!registry) { registryContract(*outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2,
                                      JSTI_REGISTRY_STAGE_DESTROY_V2); return -1; }
    if (!*registry) return 0;
    if ((*registry)->active) {
        registryContract(*outcome, JSTI_REGISTRY_CONTRACT_REENTRANT_V2, JSTI_REGISTRY_STAGE_DESTROY_V2);
        return -1;
    }
    registryCloseV2(**registry, *outcome);
    delete *registry;
    *registry = nullptr;
    return outcome->cause_count ? -1 : 0;
}

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
