// The registry's handle slots and the fences every call re-checks: identity,
// attributes, owner and ACL, and the held ancestry back to the drive.
#include "WindowsRecordingRegistryV2Internal.hpp"

using namespace jsti_file_security;
using namespace jsti::registryV2;

size_t JSTIRecordingRegistryV2::reserve(JSTIRegistryOutcomeV2 &outcome) {
    for (size_t index = 0; index < resources.size(); ++index) {
        if (!resources[index].value) return index;
    }
    registryContract(outcome, JSTI_REGISTRY_CONTRACT_BUDGET_V2, JSTI_REGISTRY_STAGE_ADMISSION_V2);
    return resources.size();
}

void JSTIRecordingRegistryV2::acquire(size_t index, HANDLE value, bool local) {
    resources[index] = {value, nextID++, local, {}};
}

void JSTIRecordingRegistryV2::release(size_t index, JSTIRegistryOutcomeV2 &outcome) {
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

void JSTIRecordingRegistryV2::releaseAll(JSTIRegistryOutcomeV2 &outcome) {
    for (size_t index = resources.size(); index > 0; --index) release(index - 1, outcome);
}

bool JSTIRecordingRegistryV2::identity(size_t index, JSTIRegistryIdentityV2 &result,
                                       JSTIRegistryOutcomeV2 &outcome, uint32_t stage) {
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

bool JSTIRecordingRegistryV2::attributes(size_t index, bool directoryExpected, bool immutable,
                                         JSTIRegistryOutcomeV2 &outcome) {
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

bool JSTIRecordingRegistryV2::permissions(size_t index, bool privateExpected,
                                          JSTIRegistryOutcomeV2 &outcome) {
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

bool JSTIRecordingRegistryV2::openRelativeV2(size_t parent, const std::wstring &name, ACCESS_MASK access,
                                             ULONG disposition, bool directoryExpected,
                                             PSECURITY_DESCRIPTOR descriptor, ULONG sharing, size_t &result,
                                             JSTIRegistryOutcomeV2 &outcome) {
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

bool JSTIRecordingRegistryV2::attributesCheckAndCapture(size_t index, bool directoryExpected,
                                                        JSTIRegistryOutcomeV2 &outcome) {
    return attributes(index, directoryExpected, false, outcome) &&
        identity(index, resources[index].identity, outcome);
}

bool JSTIRecordingRegistryV2::validate(JSTIRegistryOutcomeV2 &outcome) {
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
