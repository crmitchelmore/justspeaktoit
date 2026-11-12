// The immutable recording namespace (v2): typed outcomes, and opening, validating, closing and
// destroying the registry. Leaves and fences live in their own units (see the internal header).
#include "WindowsRecordingRegistryV2Internal.hpp"

using namespace jsti_file_security;

namespace jsti::registryV2 {

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
                   uint64_t resource, bool cleanup) {
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

bool registryInput(const uint8_t *bytes, size_t count, size_t maximum, std::string &result,
                   JSTIRegistryOutcomeV2 &outcome) {
    if (!bytes || !count || count > maximum || std::memchr(bytes, 0, count)) {
        registryContract(outcome, JSTI_REGISTRY_CONTRACT_INVALID_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
        return false;
    }
    result.assign(reinterpret_cast<const char *>(bytes), count);
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

} // namespace jsti::registryV2

using namespace jsti::registryV2;

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
