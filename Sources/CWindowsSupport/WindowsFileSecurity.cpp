#include "WindowsFileSecurityInternal.hpp"

namespace jsti_file_security {
HeldRootSetInformation heldRootSetInformation() {
    static const auto resolved = [] {
        const HMODULE module = GetModuleHandleW(L"ntdll.dll");
        return module ?
            reinterpret_cast<HeldRootSetInformation>(GetProcAddress(module, "NtSetInformationFile")) : nullptr;
    }();
    return resolved;
}

bool parsePath(const char *utf8, std::vector<std::wstring> &components, std::string &error) {
    std::wstring path;
    if (!jsti::wide(utf8, path) || path.empty() || path.size() > 32000) {
        error = "Private staging requires a valid, non-empty UTF-8 path.";
        return false;
    }
    std::replace(path.begin(), path.end(), L'/', L'\\');
    if (path.compare(0, 4, L"\\\\?\\") == 0) path.erase(0, 4);
    if (path.size() < 4 || !((path[0] >= L'A' && path[0] <= L'Z') ||
                            (path[0] >= L'a' && path[0] <= L'z')) ||
        path[1] != L':' || path[2] != L'\\') {
        error = "Private staging requires an absolute local drive path with a leaf name.";
        return false;
    }
    components.push_back(L"\\\\?\\" + path.substr(0, 3));
    size_t start = 3;
    while (start < path.size()) {
        const size_t end = path.find(L'\\', start);
        const std::wstring part = path.substr(start, end == std::wstring::npos ? end : end - start);
        if (part.empty() || part == L"." || part == L".." || part.back() == L'.' ||
            part.back() == L' ' || part.find_first_of(L"<>:\"|?*") != std::wstring::npos ||
            std::any_of(part.begin(), part.end(), [](wchar_t ch) { return ch < 32; })) {
            error = "Private staging path contains an unsafe component.";
            return false;
        }
        components.push_back(part);
        if (end == std::wstring::npos) break;
        start = end + 1;
        if (start == path.size()) {
            error = "Private staging path must not end with a separator.";
            return false;
        }
    }
    return components.size() > 1;
}

bool checkDirectory(HANDLE handle, std::string &error) {
    FILE_ATTRIBUTE_TAG_INFO attributes = {};
    if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &attributes, sizeof(attributes))) {
        error = jsti::systemError("Read staging directory attributes");
        return false;
    }
    if (!(attributes.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        error = "Private staging refuses non-directory paths and reparse points.";
        return false;
    }
    return true;
}

bool openRelative(HANDLE parent, const std::wstring &name, ACCESS_MASK access,
                  ULONG disposition, bool directory, PSECURITY_DESCRIPTOR security,
                  jsti::Handle &result, std::string &error, ULONG sharing) {
    UNICODE_STRING unicode = {};
    unicode.Buffer = const_cast<PWSTR>(name.c_str());
    unicode.Length = static_cast<USHORT>(name.size() * sizeof(wchar_t));
    unicode.MaximumLength = unicode.Length;
    OBJECT_ATTRIBUTES attributes = {};
    attributes.Length = sizeof(attributes);
    attributes.RootDirectory = parent;
    attributes.ObjectName = &unicode;
    attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE;
    attributes.SecurityDescriptor = security;
    IO_STATUS_BLOCK status = {};
    const NTSTATUS code = NtCreateFile(&result.value, access | SYNCHRONIZE, &attributes, &status,
                                       nullptr, FILE_ATTRIBUTE_NORMAL, sharing,
                                       disposition, FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT |
                                       (directory ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE), nullptr, 0);
    if (code < 0) {
        result.value = nullptr;
        error = jsti::systemError("Open private staging path without reparsing", RtlNtStatusToDosError(code));
        return false;
    }
    return !directory || checkDirectory(result.value, error);
}

// Retain every ancestor without delete sharing until creation/repair finishes.
// Names are single components relative to handles, so a junction substitution
// or ancestor rename cannot redirect a later step into an unrelated directory.
bool openParents(const std::vector<std::wstring> &components,
                 std::vector<std::unique_ptr<jsti::Handle>> &parents, std::string &error) {
    auto root = std::make_unique<jsti::Handle>();
    root->value = CreateFileW(components.front().c_str(), FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                              FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (root->value == INVALID_HANDLE_VALUE) {
        error = jsti::systemError("Open private staging drive");
        return false;
    }
    if (!checkDirectory(root->value, error)) return false;
    parents.push_back(std::move(root));
    for (size_t index = 1; index + 1 < components.size(); ++index) {
        auto child = std::make_unique<jsti::Handle>();
        if (!openRelative(parents.back()->value, components[index],
                          FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL,
                          FILE_OPEN, true, nullptr, *child, error)) return false;
        parents.push_back(std::move(child));
    }
    return true;
}

bool verifyOwner(HANDLE handle, const PrivateSecurity &security, std::string &error) {
    PSID owner = nullptr;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    const DWORD code = GetSecurityInfo(handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
                                       &owner, nullptr, nullptr, nullptr, &descriptor);
    LocalMemory memory;
    memory.value = descriptor;
    if (code != ERROR_SUCCESS) {
        error = jsti::systemError("Read staging owner", code);
        return false;
    }
    if (!owner || !EqualSid(owner, security.userSID())) {
        error = "Private staging refuses a directory owned by another account.";
        return false;
    }
    return true;
}

PrivateDescriptorCheck privateDescriptorCheck(PSID owner, PACL acl, PSECURITY_DESCRIPTOR descriptor,
                                               const PrivateSecurity &security, DWORD &nativeError) {
    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    const bool sameUserAndSystem = EqualSid(security.userSID(), const_cast<BYTE *>(security.system)) != FALSE;
    bool userAllowed = false;
    bool systemAllowed = false;
    if (!owner || !EqualSid(owner, security.userSID()) || !acl || !IsValidAcl(acl)) {
        return PrivateDescriptorCheck::descriptor;
    }
    if (!GetSecurityDescriptorControl(descriptor, &control, &revision)) {
        nativeError = GetLastError();
        return PrivateDescriptorCheck::descriptor;
    }
    if (!(control & SE_DACL_PROTECTED) ||
        acl->AceCount != (sameUserAndSystem ? 1 : 2)) return PrivateDescriptorCheck::descriptor;
    for (DWORD index = 0; index < acl->AceCount; ++index) {
        void *raw = nullptr;
        if (!GetAce(acl, index, &raw)) {
            nativeError = GetLastError();
            return PrivateDescriptorCheck::entryRead;
        }
        auto *entry = static_cast<ACCESS_ALLOWED_ACE *>(raw);
        if (entry->Header.AceType != ACCESS_ALLOWED_ACE_TYPE || entry->Header.AceFlags != 0 ||
            entry->Mask != FILE_ALL_ACCESS) return PrivateDescriptorCheck::entry;
        PSID sid = &entry->SidStart;
        const bool isUser = EqualSid(sid, security.userSID()) != FALSE;
        const bool isSystem = EqualSid(sid, const_cast<BYTE *>(security.system)) != FALSE;
        if ((!isUser && !isSystem) || (isUser && userAllowed) || (isSystem && systemAllowed)) {
            return PrivateDescriptorCheck::account;
        }
        userAllowed = userAllowed || isUser;
        systemAllowed = systemAllowed || isSystem;
    }
    return userAllowed && systemAllowed ? PrivateDescriptorCheck::valid : PrivateDescriptorCheck::missing;
}

bool verifyPrivate(HANDLE handle, const PrivateSecurity &security, std::string &error) {
    PSID owner = nullptr;
    PACL acl = nullptr;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    const DWORD code = GetSecurityInfo(handle, SE_FILE_OBJECT,
                                       OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                                       &owner, nullptr, &acl, nullptr, &descriptor);
    LocalMemory memory;
    memory.value = descriptor;
    if (code != ERROR_SUCCESS) {
        error = jsti::systemError("Verify private staging permissions", code);
        return false;
    }
    DWORD nativeError = 0;
    switch (privateDescriptorCheck(owner, acl, descriptor, security, nativeError)) {
    case PrivateDescriptorCheck::valid: return true;
    case PrivateDescriptorCheck::descriptor:
        error = "Private staging ownership or protected permissions could not be verified.";
        return false;
    case PrivateDescriptorCheck::entryRead:
        error = jsti::systemError("Read private staging access entry", nativeError);
        return false;
    case PrivateDescriptorCheck::entry:
        error = "Private staging has an unexpected access entry.";
        return false;
    case PrivateDescriptorCheck::account:
        error = "Private staging grants access to an unexpected or repeated account.";
        return false;
    case PrivateDescriptorCheck::missing:
        error = "Private staging is missing required user or SYSTEM access.";
        return false;
    }
    return false;
}

int prepareDirectory(const char *path, char *error, size_t capacity) {
    try {
        std::string detail;
        std::vector<std::wstring> components;
        PrivateSecurity security;
        std::vector<std::unique_ptr<jsti::Handle>> parents;
        if (!parsePath(path, components, detail) || !security.initialise(detail) ||
            !openParents(components, parents, detail)) return jsti::fail(detail, error, capacity);
        jsti::Handle leaf;
        const ACCESS_MASK access = READ_CONTROL | FILE_READ_ATTRIBUTES | WRITE_DAC;
        if (!openRelative(parents.back()->value, components.back(), access,
                          FILE_OPEN_IF, true, &security.descriptor, leaf, detail)) {
            return jsti::fail(detail, error, capacity);
        }
        if (!verifyOwner(leaf.value, security, detail)) return jsti::fail(detail, error, capacity);
        const DWORD code = SetSecurityInfo(leaf.value, SE_FILE_OBJECT,
                                           DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                           nullptr, nullptr, static_cast<PACL>(security.acl.value), nullptr);
        if (code != ERROR_SUCCESS) {
            return jsti::fail(jsti::systemError("Protect staging directory permissions", code), error, capacity);
        }
        if (!verifyPrivate(leaf.value, security, detail)) return jsti::fail(detail, error, capacity);
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Private staging could not allocate its security state.", error, capacity);
    }
}

// Junction creation needs no symbolic-link privilege. Kept inside the self-test
// so CI exercises real reparse rejection rather than a mocked attribute flag.
bool createTestJunction(const std::wstring &path, const std::wstring &target, std::string &error) {
    if (!CreateDirectoryW(path.c_str(), nullptr)) {
        error = jsti::systemError("Create test junction directory");
        return false;
    }
    jsti::Handle handle;
    handle.value = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                               FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (handle.value == INVALID_HANDLE_VALUE) {
        error = jsti::systemError("Open test junction");
        return false;
    }
    struct MountPoint {
        DWORD tag;
        WORD dataLength, reserved;
        WORD substituteOffset, substituteLength, printOffset, printLength;
        WCHAR paths[1];
    };
    const std::wstring substitute = L"\\??\\" + target;
    const size_t pathBytes = (substitute.size() + target.size() + 2) * sizeof(WCHAR);
    const size_t size = offsetof(MountPoint, paths) + pathBytes;
    if (size > MAXIMUM_REPARSE_DATA_BUFFER_SIZE) {
        error = "Self-test temporary path is too long for a junction.";
        return false;
    }
    std::vector<BYTE> bytes(size, 0);
    auto *buffer = reinterpret_cast<MountPoint *>(bytes.data());
    buffer->tag = IO_REPARSE_TAG_MOUNT_POINT;
    buffer->dataLength = static_cast<WORD>(size - 8);
    buffer->substituteLength = static_cast<WORD>(substitute.size() * sizeof(WCHAR));
    buffer->printOffset = static_cast<WORD>((substitute.size() + 1) * sizeof(WCHAR));
    buffer->printLength = static_cast<WORD>(target.size() * sizeof(WCHAR));
    std::memcpy(buffer->paths, substitute.c_str(), (substitute.size() + 1) * sizeof(WCHAR));
    std::memcpy(reinterpret_cast<BYTE *>(buffer->paths) + buffer->printOffset,
                target.c_str(), (target.size() + 1) * sizeof(WCHAR));
    DWORD returned = 0;
    if (!DeviceIoControl(handle.value, FSCTL_SET_REPARSE_POINT, bytes.data(), static_cast<DWORD>(size),
                          nullptr, 0, &returned, nullptr)) {
        error = jsti::systemError("Create self-test junction reparse point");
        return false;
    }
    return true;
}
} // namespace jsti_file_security

using namespace jsti_file_security;

HANDLE jsti::createPrivateFileHandle(const char *path, std::string &error) {
    try {
        std::vector<std::wstring> components;
        PrivateSecurity security;
        std::vector<std::unique_ptr<jsti::Handle>> parents;
        if (!parsePath(path, components, error) || !security.initialise(error) ||
            !openParents(components, parents, error)) return INVALID_HANDLE_VALUE;
        if (!verifyPrivate(parents.back()->value, security, error)) {
            error = "Output file parent is not private: " + error;
            return INVALID_HANDLE_VALUE;
        }
        jsti::Handle leaf;
        const ACCESS_MASK access = READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_READ_DATA | FILE_WRITE_DATA | DELETE;
        if (!openRelative(parents.back()->value, components.back(), access,
                          FILE_CREATE, false, &security.descriptor, leaf, error)) return INVALID_HANDLE_VALUE;
        if (!verifyPrivate(leaf.value, security, error)) {
            FILE_DISPOSITION_INFO disposition{TRUE};
            if (!SetFileInformationByHandle(leaf.value, FileDispositionInfo, &disposition, sizeof(disposition))) {
                error += " " + jsti::systemError("Remove invalid private output");
            }
            return INVALID_HANDLE_VALUE;
        }
        const HANDLE handle = leaf.value;
        leaf.value = nullptr;
        return handle;
    } catch (const std::exception &) {
        error = "Private staging could not allocate its security state.";
        return INVALID_HANDLE_VALUE;
    }
}

int jsti_private_directory_prepare(const char *path, char *error, size_t capacity) {
    return prepareDirectory(path, error, capacity);
}

int jsti_private_directory_create(const char *path, char *error, size_t capacity) {
    try {
        std::string detail;
        std::vector<std::wstring> components;
        PrivateSecurity security;
        std::vector<std::unique_ptr<jsti::Handle>> parents;
        if (!parsePath(path, components, detail) || !security.initialise(detail) ||
            !openParents(components, parents, detail)) return jsti::fail(detail, error, capacity);
        jsti::Handle leaf;
        const ACCESS_MASK access = READ_CONTROL | FILE_READ_ATTRIBUTES | DELETE;
        if (!openRelative(parents.back()->value, components.back(), access,
                          FILE_CREATE, true, &security.descriptor, leaf, detail)) {
            return jsti::fail(detail, error, capacity);
        }
        if (!verifyPrivate(leaf.value, security, detail)) {
            FILE_DISPOSITION_INFO disposition{TRUE};
            if (!SetFileInformationByHandle(leaf.value, FileDispositionInfo, &disposition, sizeof(disposition))) {
                detail += " " + jsti::systemError("Remove invalid private directory");
            }
            return jsti::fail(detail, error, capacity);
        }
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Private directory creation could not allocate its security state.", error, capacity);
    }
}

int jsti_private_file_create(const char *path, char *error, size_t capacity) {
    std::string detail;
    jsti::Handle file;
    file.value = jsti::createPrivateFileHandle(path, detail);
    if (file.value == INVALID_HANDLE_VALUE) return jsti::fail(detail, error, capacity);
    if (error && capacity) error[0] = 0;
    return 0;
}
