// The immutable recording namespace (v2): the held-handle registry and its
// typed outcomes. WindowsRecordingRegistryV2.cpp opens, validates and closes
// it; WindowsRecordingRegistryV2Fences.cpp owns its handle slots and fences;
// WindowsRecordingRegistryV2Leaves.cpp appends, reads and lists leaves.
// Not public ABI.
#pragma once

#include "WindowsFileSecurityInternal.hpp"
#include <array>
#include <string>
#include <vector>

namespace jsti::registryV2 {

// Resets a caller's outcome for one call; false when its ABI header is wrong.
bool registryOutcome(JSTIRegistryOutcomeV2 *outcome);
void registryCause(JSTIRegistryOutcomeV2 &outcome, uint32_t domain, uint32_t code, uint32_t stage,
                   uint64_t resource = 0, bool cleanup = false);
void registryContract(JSTIRegistryOutcomeV2 &outcome, uint32_t code, uint32_t stage);
bool registrySame(const JSTIRegistryIdentityV2 &first, const JSTIRegistryIdentityV2 &second);
bool registryInput(const uint8_t *bytes, size_t count, size_t maximum, std::string &result,
                   JSTIRegistryOutcomeV2 &outcome);

struct RegistryResourceV2 {
    HANDLE value = nullptr;
    uint64_t id = 0;
    bool localMemory = false;
    JSTIRegistryIdentityV2 identity{};
};

} // namespace jsti::registryV2

// Every handle, token and local allocation the registry holds lives in one of
// its fixed resource slots, so close releases exactly what was acquired.
struct JSTIRecordingRegistryV2 {
    jsti_file_security::PrivateSecurity security;
    std::array<jsti::registryV2::RegistryResourceV2, JSTI_REGISTRY_MAX_RESOURCES_V2> resources{};
    std::vector<std::wstring> components;
    std::vector<size_t> parents;
    const std::wstring namespaceName = L".recording-locations";
    size_t directory = 0;
    uint64_t nextID = 1;
    bool active = false, closed = false, poisoned = false;
    JSTIRegistryOutcomeV2 closeOutcome{};
    JSTIRegistryOutcomeV2 poisonOutcome{};

    ~JSTIRecordingRegistryV2() { security.acl.value = nullptr; }

    size_t reserve(JSTIRegistryOutcomeV2 &outcome);
    void acquire(size_t index, HANDLE value, bool local = false);
    void release(size_t index, JSTIRegistryOutcomeV2 &outcome);
    void releaseAll(JSTIRegistryOutcomeV2 &outcome);
    bool identity(size_t index, JSTIRegistryIdentityV2 &result, JSTIRegistryOutcomeV2 &outcome,
                  uint32_t stage = JSTI_REGISTRY_STAGE_IDENTITY_V2);
    bool attributes(size_t index, bool directoryExpected, bool immutable, JSTIRegistryOutcomeV2 &outcome);
    bool permissions(size_t index, bool privateExpected, JSTIRegistryOutcomeV2 &outcome);
    bool openRelativeV2(size_t parent, const std::wstring &name, ACCESS_MASK access, ULONG disposition,
                        bool directoryExpected, PSECURITY_DESCRIPTOR descriptor, ULONG sharing,
                        size_t &result, JSTIRegistryOutcomeV2 &outcome);
    bool attributesCheckAndCapture(size_t index, bool directoryExpected, JSTIRegistryOutcomeV2 &outcome);
    bool validate(JSTIRegistryOutcomeV2 &outcome);
};

namespace jsti::registryV2 {

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

void registryCloseV2(JSTIRecordingRegistryV2 &registry, JSTIRegistryOutcomeV2 &outcome);

} // namespace jsti::registryV2
