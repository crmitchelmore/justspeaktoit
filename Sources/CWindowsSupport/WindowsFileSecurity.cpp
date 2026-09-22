#include "CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <aclapi.h>
#include <winternl.h>
#include <winioctl.h>
#include <objbase.h>
#include <exception>
#include <iterator>
#include <memory>
#include <vector>

namespace {
struct LocalMemory {
    void *value = nullptr;
    ~LocalMemory() { if (value) LocalFree(value); }
};

struct PrivateSecurity {
    std::vector<BYTE> user;
    BYTE system[SECURITY_MAX_SID_SIZE] = {};
    LocalMemory acl;
    SECURITY_DESCRIPTOR descriptor = {};

    PSID userSID() const { return reinterpret_cast<const TOKEN_USER *>(user.data())->User.Sid; }

    bool initialise(std::string &error) {
        jsti::Handle token;
        if (!OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &token.value)) {
            const DWORD code = GetLastError();
            if (code != ERROR_NO_TOKEN) {
                error = jsti::systemError("OpenThreadToken", code);
                return false;
            }
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token.value)) {
                error = jsti::systemError("OpenProcessToken");
                return false;
            }
        }
        DWORD size = 0;
        GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || !size) {
            error = jsti::systemError("GetTokenInformation size");
            return false;
        }
        user.resize(size);
        if (!GetTokenInformation(token.value, TokenUser, user.data(), size, &size)) {
            error = jsti::systemError("GetTokenInformation");
            return false;
        }
        DWORD systemSize = sizeof(system);
        if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system, &systemSize)) {
            error = jsti::systemError("CreateWellKnownSid");
            return false;
        }
        EXPLICIT_ACCESSW entries[2] = {};
        PSID trustees[] = {userSID(), system};
        const ULONG count = EqualSid(trustees[0], trustees[1]) ? 1 : 2;
        for (ULONG index = 0; index < count; ++index) {
            entries[index].grfAccessPermissions = FILE_ALL_ACCESS;
            entries[index].grfAccessMode = SET_ACCESS;
            // Each file gets an explicit ACL; repairing this directory must not
            // propagate permission changes into pre-existing children.
            entries[index].grfInheritance = NO_INHERITANCE;
            BuildTrusteeWithSidW(&entries[index].Trustee, trustees[index]);
        }
        PACL result = nullptr;
        const DWORD code = SetEntriesInAclW(count, entries, nullptr, &result);
        acl.value = result;
        if (code != ERROR_SUCCESS) {
            error = jsti::systemError("SetEntriesInAcl", code);
            return false;
        }
        if (!InitializeSecurityDescriptor(&descriptor, SECURITY_DESCRIPTOR_REVISION) ||
            !SetSecurityDescriptorOwner(&descriptor, userSID(), FALSE) ||
            !SetSecurityDescriptorDacl(&descriptor, TRUE, result, FALSE) ||
            !SetSecurityDescriptorControl(&descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED)) {
            error = jsti::systemError("Create private security descriptor");
            return false;
        }
        return true;
    }
};

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
                  jsti::Handle &result, std::string &error) {
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
                                       nullptr, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ | FILE_SHARE_WRITE,
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
    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    const bool sameUserAndSystem = EqualSid(security.userSID(), const_cast<BYTE *>(security.system)) != FALSE;
    bool userAllowed = false;
    bool systemAllowed = false;
    if (!owner || !EqualSid(owner, security.userSID()) || !acl || !IsValidAcl(acl) ||
        !GetSecurityDescriptorControl(descriptor, &control, &revision) || !(control & SE_DACL_PROTECTED) ||
        acl->AceCount != (sameUserAndSystem ? 1 : 2)) {
        error = "Private staging ownership or protected permissions could not be verified.";
        return false;
    }
    for (DWORD index = 0; index < acl->AceCount; ++index) {
        void *raw = nullptr;
        if (!GetAce(acl, index, &raw)) {
            error = jsti::systemError("Read private staging access entry");
            return false;
        }
        auto *entry = static_cast<ACCESS_ALLOWED_ACE *>(raw);
        if (entry->Header.AceType != ACCESS_ALLOWED_ACE_TYPE || entry->Header.AceFlags != 0 ||
            entry->Mask != FILE_ALL_ACCESS) {
            error = "Private staging has an unexpected access entry.";
            return false;
        }
        PSID sid = &entry->SidStart;
        const bool isUser = EqualSid(sid, security.userSID()) != FALSE;
        const bool isSystem = EqualSid(sid, const_cast<BYTE *>(security.system)) != FALSE;
        if ((!isUser && !isSystem) || (isUser && userAllowed) || (isSystem && systemAllowed)) {
            error = "Private staging grants access to an unexpected or repeated account.";
            return false;
        }
        userAllowed = userAllowed || isUser;
        systemAllowed = systemAllowed || isSystem;
    }
    if (!userAllowed || !systemAllowed) {
        error = "Private staging is missing required user or SYSTEM access.";
        return false;
    }
    return true;
}

int prepare(const char *path, bool directory, char *error, size_t capacity) {
    try {
        std::string detail;
        std::vector<std::wstring> components;
        PrivateSecurity security;
        std::vector<std::unique_ptr<jsti::Handle>> parents;
        if (!parsePath(path, components, detail) || !security.initialise(detail) ||
            !openParents(components, parents, detail)) return jsti::fail(detail, error, capacity);
        if (!directory && !verifyPrivate(parents.back()->value, security, detail)) {
            return jsti::fail("Multipart file parent is not private: " + detail, error, capacity);
        }
        jsti::Handle leaf;
        const ACCESS_MASK access = READ_CONTROL | FILE_READ_ATTRIBUTES | (directory ? WRITE_DAC : FILE_WRITE_DATA);
        if (!openRelative(parents.back()->value, components.back(), access,
                          directory ? FILE_OPEN_IF : FILE_CREATE, directory, &security.descriptor, leaf, detail)) {
            return jsti::fail(detail, error, capacity);
        }
        if (directory) {
            if (!verifyOwner(leaf.value, security, detail)) return jsti::fail(detail, error, capacity);
            const DWORD code = SetSecurityInfo(leaf.value, SE_FILE_OBJECT,
                                               DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                               nullptr, nullptr, static_cast<PACL>(security.acl.value), nullptr);
            if (code != ERROR_SUCCESS) {
                return jsti::fail(jsti::systemError("Protect staging directory permissions", code), error, capacity);
            }
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

struct TestFiles {
    std::wstring root, file, target, junction;
    bool cleanUp(std::string *error = nullptr) {
        bool success = true;
        auto remove = [&](std::wstring &path, bool directory) {
            if (path.empty()) return;
            if (!(directory ? RemoveDirectoryW(path.c_str()) : DeleteFileW(path.c_str()))) {
                const DWORD code = GetLastError();
                if (code != ERROR_FILE_NOT_FOUND && code != ERROR_PATH_NOT_FOUND) {
                    success = false;
                    if (error && error->empty()) *error = jsti::systemError("Remove security self-test artefact", code);
                }
            }
            path.clear();
        };
        remove(junction, true);
        remove(target, true);
        remove(file, false);
        remove(root, true);
        return success;
    }
    ~TestFiles() { cleanUp(); }
};
} // namespace

int jsti_private_directory_prepare(const char *path, char *error, size_t capacity) {
    return prepare(path, true, error, capacity);
}

int jsti_private_file_create(const char *path, char *error, size_t capacity) {
    return prepare(path, false, error, capacity);
}

int jsti_private_storage_self_test(char *error, size_t capacity) {
    try {
        char localError[1024] = {};
        const char *invalid[] = {"", "relative\\upload", "C:\\", "C:\\folder\\..\\upload", "C:\\upload:stream", "\xc3\x28"};
        for (const char *path : invalid) {
            if (jsti_private_directory_prepare(path, localError, sizeof(localError)) != -1 || !localError[0] ||
                jsti_private_file_create(path, localError, sizeof(localError)) != -1 || !localError[0]) {
                return jsti::fail("Private storage accepted an unsafe test path.", error, capacity);
            }
        }
        wchar_t temporary[32768] = {};
        const DWORD count = GetTempPathW(static_cast<DWORD>(std::size(temporary)), temporary);
        GUID guid = {};
        wchar_t identifier[40] = {};
        if (!count || count >= std::size(temporary) || FAILED(CoCreateGuid(&guid)) ||
            !StringFromGUID2(guid, identifier, static_cast<int>(std::size(identifier)))) {
            return jsti::fail("Private storage self-test could not create a unique temporary path.", error, capacity);
        }
        TestFiles paths;
        const std::wstring testRoot = std::wstring(temporary) + L"JustSpeakToIt-security-test-" + identifier;
        // Establish exclusive ownership before preparing or later removing the
        // leaf, even in the extremely unlikely event of a GUID collision. An
        // elevated token's default owner can be Administrators rather than
        // TokenUser, so the synthetic root needs the same explicit owner as
        // production staging. Do not weaken existing-directory owner checks.
        PrivateSecurity testSecurity;
        std::string securityError;
        if (!testSecurity.initialise(securityError)) return jsti::fail(securityError, error, capacity);
        SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), &testSecurity.descriptor, FALSE};
        if (!CreateDirectoryW(testRoot.c_str(), &attributes)) {
            return jsti::fail(jsti::systemError("Create unique security test directory"), error, capacity);
        }
        paths.root = testRoot;
        paths.file = paths.root + L"\\upload.multipart";
        paths.target = paths.root + L"\\junction-target";
        paths.junction = paths.root + L"\\junction";
        const std::string root = jsti::utf8(paths.root);
        const std::string file = jsti::utf8(paths.file);
        if (jsti_private_directory_prepare(root.c_str(), localError, sizeof(localError)) != 0 ||
            jsti_private_file_create(file.c_str(), localError, sizeof(localError)) != 0) {
            return jsti::fail(localError, error, capacity);
        }
        {
            jsti::Handle handle;
            handle.value = CreateFileW(paths.file.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                       OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            const char sentinel[] = "private synthetic multipart test";
            DWORD written = 0;
            if (handle.value == INVALID_HANDLE_VALUE ||
                !WriteFile(handle.value, sentinel, sizeof(sentinel), &written, nullptr) || written != sizeof(sentinel)) {
                return jsti::fail(jsti::systemError("Write private self-test file"), error, capacity);
            }
        }
        if (jsti_private_file_create(file.c_str(), localError, sizeof(localError)) != -1 || !localError[0]) {
            return jsti::fail("Private storage overwrote an existing file.", error, capacity);
        }
        {
            jsti::Handle handle;
            handle.value = CreateFileW(paths.file.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                                       OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            char content[64] = {};
            DWORD read = 0;
            if (handle.value == INVALID_HANDLE_VALUE ||
                !ReadFile(handle.value, content, sizeof(content), &read, nullptr) ||
                read != sizeof("private synthetic multipart test") ||
                std::strcmp(content, "private synthetic multipart test") != 0) {
                return jsti::fail("Private storage did not preserve existing file bytes.", error, capacity);
            }
        }
        // Deliberately weaken only the unique synthetic directory, then verify
        // preparation repairs it. Real recordings/credentials are never touched.
        {
            jsti::Handle handle;
            handle.value = CreateFileW(paths.root.c_str(), WRITE_DAC, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                       nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
            if (handle.value == INVALID_HANDLE_VALUE) {
                return jsti::fail(jsti::systemError("Open test directory for ACL repair"), error, capacity);
            }
            const DWORD code = SetSecurityInfo(handle.value, SE_FILE_OBJECT,
                                               DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                               nullptr, nullptr, nullptr, nullptr);
            if (code != ERROR_SUCCESS) {
                return jsti::fail(jsti::systemError("Set synthetic directory test ACL", code), error, capacity);
            }
        }
        if (jsti_private_file_create((root + "/refused.multipart").c_str(), localError, sizeof(localError)) != -1 ||
            !localError[0] || jsti_private_directory_prepare(root.c_str(), localError, sizeof(localError)) != 0) {
            return jsti::fail("Private storage failed its directory-permission repair test.", error, capacity);
        }
        std::string detail;
        if (jsti_private_directory_prepare(jsti::utf8(paths.target).c_str(), localError, sizeof(localError)) != 0) {
            return jsti::fail(localError, error, capacity);
        }
        if (
            !createTestJunction(paths.junction, paths.target, detail)) {
            return jsti::fail(detail, error, capacity);
        }
        const std::string junction = jsti::utf8(paths.junction);
        if (jsti_private_directory_prepare(junction.c_str(), localError, sizeof(localError)) != -1 || !localError[0] ||
            jsti_private_file_create((junction + "/escape.multipart").c_str(), localError, sizeof(localError)) != -1 ||
            !localError[0] || GetFileAttributesW((paths.target + L"\\escape.multipart").c_str()) != INVALID_FILE_ATTRIBUTES) {
            return jsti::fail("Private storage followed a junction in its self-test.", error, capacity);
        }
        if (!paths.cleanUp(&detail)) return jsti::fail(detail, error, capacity);
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Private storage self-test could not allocate its state.", error, capacity);
    }
}
