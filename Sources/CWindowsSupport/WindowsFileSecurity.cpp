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
#include <array>

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
                  jsti::Handle &result, std::string &error,
                  ULONG sharing = FILE_SHARE_READ | FILE_SHARE_WRITE) {
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

struct TestFiles {
    std::wstring root, file, target, junction, exclusiveDirectory;
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
        remove(exclusiveDirectory, true);
        remove(root, true);
        return success;
    }
    ~TestFiles() { cleanUp(); }
};
} // namespace

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

struct JSTIOwnedCaptureFile {
    PrivateSecurity security;
    std::vector<std::unique_ptr<jsti::Handle>> anchors;
    jsti::Handle file;
    bool closed = false;
    bool removed = false;

    bool requireOpen(std::string &error) const {
        if (closed || removed || !file.value || file.value == INVALID_HANDLE_VALUE) {
            error = "The held recording file is closed or discarded.";
            return false;
        }
        return true;
    }

    bool validate(std::string &error) const {
        if (!requireOpen(error)) return false;
        for (const auto &anchor : anchors) {
            if (!checkDirectory(anchor->value, error)) return false;
        }
        if (anchors.empty() || !verifyPrivate(anchors.back()->value, security, error) ||
            !verifyPrivate(file.value, security, error)) return false;
        FILE_ATTRIBUTE_TAG_INFO attributes{};
        BY_HANDLE_FILE_INFORMATION identity{};
        if (!GetFileInformationByHandleEx(file.value, FileAttributeTagInfo, &attributes, sizeof(attributes)) ||
            !GetFileInformationByHandle(file.value, &identity)) {
            error = jsti::systemError("Inspect held recording file");
            return false;
        }
        if (GetFileType(file.value) != FILE_TYPE_DISK ||
            (attributes.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
            identity.nNumberOfLinks != 1) {
            error = "Held recording audio must be a regular non-reparse file with exactly one link.";
            return false;
        }
        return true;
    }

    bool discard(std::string &error) {
        if (!requireOpen(error)) return false;
        // The actual exclusively created handle is deletion authority, not a
        // pathname, identity reread, or compare-and-swap receipt.
        FILE_DISPOSITION_INFO disposition{TRUE};
        if (!SetFileInformationByHandle(file.value, FileDispositionInfo, &disposition, sizeof(disposition))) {
            error = jsti::systemError("Discard held unpublished recording");
            return false;
        }
        removed = true;
        return true;
    }

    bool close(std::string &error) {
        if (closed) return true;
        closed = true;
        bool success = true;
        auto release = [&](jsti::Handle &owned) {
            if (!owned.value || owned.value == INVALID_HANDLE_VALUE) return;
            const HANDLE handle = owned.value;
            owned.value = nullptr;
            if (!CloseHandle(handle)) {
                if (!error.empty()) error += " ";
                error += jsti::systemError("Close held recording capability");
                success = false;
            }
        };
        release(file);
        for (auto iterator = anchors.rbegin(); iterator != anchors.rend(); ++iterator) release(**iterator);
        return success;
    }
};

namespace {
bool captureUUID(const char *value, std::wstring &result, std::string &error) {
    if (!value || std::strlen(value) != 36) {
        error = "Held capture identifiers must be UUID strings.";
        return false;
    }
    for (size_t index = 0; index < 36; ++index) {
        const char ch = value[index];
        const bool separator = index == 8 || index == 13 || index == 18 || index == 23;
        if (separator ? ch != '-' : !((ch >= '0' && ch <= '9') ||
                                      (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F'))) {
            error = "Held capture identifiers contain an unsafe component.";
            return false;
        }
    }
    return jsti::wide(value, result);
}

int captureResult(bool success, const std::string &detail, char *error, size_t capacity) {
    if (!success) return jsti::fail(detail, error, capacity);
    if (error && capacity) error[0] = 0;
    return 0;
}

template<class Work>
int captureOperation(JSTIOwnedCaptureFile *file, char *error, size_t capacity, Work work) {
    if (!file) return jsti::fail("Missing held recording file.", error, capacity);
    try {
        std::string detail;
        const bool success = work(*file, detail);
        return captureResult(success, detail, error, capacity);
    } catch (const std::exception &) {
        return jsti::fail("The held recording operation could not allocate its state.", error, capacity);
    }
}

int failedCaptureAllocation(std::unique_ptr<JSTIOwnedCaptureFile> &capture, std::string detail,
                            char *error, size_t capacity) {
    if (capture) {
        std::string cleanup;
        if (capture->file.value && capture->file.value != INVALID_HANDLE_VALUE && !capture->removed) {
            if (!capture->discard(cleanup)) detail += " " + cleanup;
        }
        cleanup.clear();
        if (!capture->close(cleanup)) detail += " " + cleanup;
    }
    return jsti::fail(detail, error, capacity);
}
} // namespace

int jsti_owned_capture_file_create(const char *root, const char *directoryID, const char *recordingID,
                                   JSTIOwnedCaptureFile **result, char *error, size_t capacity) {
    if (!result) return jsti::fail("A held capture output pointer is required.", error, capacity);
    *result = nullptr;
    std::unique_ptr<JSTIOwnedCaptureFile> capture;
    try {
        capture = std::make_unique<JSTIOwnedCaptureFile>();
        std::string detail;
        std::wstring directory, recording;
        std::vector<std::wstring> components;
        if (!captureUUID(directoryID, directory, detail) || !captureUUID(recordingID, recording, detail) ||
            !parsePath(root, components, detail) || !capture->security.initialise(detail) ||
            !openParents(components, capture->anchors, detail)) {
            return failedCaptureAllocation(capture, detail, error, capacity);
        }
        auto selected = std::make_unique<jsti::Handle>();
        if (!openRelative(capture->anchors.back()->value, components.back(),
                          FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL | FILE_ADD_SUBDIRECTORY,
                          FILE_OPEN, true, nullptr, *selected, detail)) {
            return failedCaptureAllocation(capture, detail, error, capacity);
        }
        capture->anchors.push_back(std::move(selected));
        auto leaf = std::make_unique<jsti::Handle>();
        if (!openRelative(capture->anchors.back()->value, directory,
                          FILE_TRAVERSE | FILE_ADD_FILE | FILE_READ_ATTRIBUTES | READ_CONTROL,
                          FILE_CREATE, true, &capture->security.descriptor, *leaf, detail) ||
            !verifyPrivate(leaf->value, capture->security, detail)) {
            return failedCaptureAllocation(capture, detail, error, capacity);
        }
        capture->anchors.push_back(std::move(leaf));
        if (!openRelative(capture->anchors.back()->value, recording + L".wav",
                          READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_READ_DATA | FILE_WRITE_DATA | DELETE,
                          FILE_CREATE, false, &capture->security.descriptor, capture->file, detail, FILE_SHARE_READ) ||
            !capture->validate(detail)) {
            return failedCaptureAllocation(capture, detail, error, capacity);
        }
        *result = capture.release();
        return captureResult(true, "", error, capacity);
    } catch (const std::exception &) {
        return failedCaptureAllocation(capture, "Could not allocate held recording state.", error, capacity);
    }
}

int jsti_owned_capture_file_write(JSTIOwnedCaptureFile *file, const uint8_t *bytes, size_t count,
                                  char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [&](auto &owned, auto &detail) {
        if (!owned.requireOpen(detail)) return false;
        if (!bytes && count) { detail = "Missing recording bytes."; return false; }
        for (size_t offset = 0; offset < count;) {
            DWORD written = 0;
            const DWORD requested = static_cast<DWORD>(std::min<size_t>(count - offset, 64 * 1024));
            if (!WriteFile(owned.file.value, bytes + offset, requested, &written, nullptr)) {
                detail = jsti::systemError("Write held recording");
                return false;
            }
            if (!written) { detail = "The held recording writer made no progress."; return false; }
            offset += written;
        }
        return true;
    });
}

int jsti_owned_capture_file_seek(JSTIOwnedCaptureFile *file, uint64_t offset, char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [&](auto &owned, auto &detail) {
        if (!owned.requireOpen(detail)) return false;
        if (offset > static_cast<uint64_t>((std::numeric_limits<LONGLONG>::max)())) {
            detail = "Held recording offset is out of range.";
            return false;
        }
        LARGE_INTEGER position{};
        position.QuadPart = static_cast<LONGLONG>(offset);
        if (!SetFilePointerEx(owned.file.value, position, nullptr, FILE_BEGIN)) {
            detail = jsti::systemError("Seek held recording");
            return false;
        }
        return true;
    });
}

int jsti_owned_capture_file_flush(JSTIOwnedCaptureFile *file, char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [](auto &owned, auto &detail) {
        if (!owned.requireOpen(detail)) return false;
        if (!FlushFileBuffers(owned.file.value)) {
            detail = jsti::systemError("Flush held recording");
            return false;
        }
        return true;
    });
}

int jsti_owned_capture_file_validate(JSTIOwnedCaptureFile *file, char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [](auto &owned, auto &detail) { return owned.validate(detail); });
}

int jsti_owned_capture_file_discard(JSTIOwnedCaptureFile *file, char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [](auto &owned, auto &detail) { return owned.discard(detail); });
}

int jsti_owned_capture_file_close(JSTIOwnedCaptureFile *file, char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [](auto &owned, auto &detail) { return owned.close(detail); });
}

void jsti_owned_capture_file_destroy(JSTIOwnedCaptureFile *file) { delete file; }

int jsti_owned_capture_file_self_test(const char *root, char *error, size_t capacity) {
    try {
        std::wstring base;
        std::string detail;
        std::vector<std::wstring> rootParts;
        GUID guid{};
        wchar_t identifier[40]{};
        if (!parsePath(root, rootParts, detail) || FAILED(CoCreateGuid(&guid)) ||
            !StringFromGUID2(guid, identifier, static_cast<int>(std::size(identifier)))) {
            return jsti::fail("Could not allocate a held-capture test identity.", error, capacity);
        }
        base = rootParts.front();
        for (size_t index = 1; index < rootParts.size(); ++index) {
            if (base.back() != L'\\') base += L'\\';
            base += rootParts[index];
        }
        const std::wstring directoryID(identifier + 1, 36);
        const std::string directory = jsti::utf8(directoryID);
        const char *recording = "00000000-0000-4000-8000-000000000002";
        const std::wstring selected = base + L"\\selected-" + directoryID;
        const std::wstring folder = selected + L"\\" + directoryID;
        const std::wstring audio = folder + L"\\00000000-0000-4000-8000-000000000002.wav";
        const std::wstring target = base + L"\\target-" + directoryID;
        const std::wstring junction = base + L"\\junction-" + directoryID;
        char local[2048]{};
        auto fail = [&](const std::string &message) { return jsti::fail(message, error, capacity); };
        if (jsti_private_directory_create(jsti::utf8(selected).c_str(), local, sizeof(local)) != 0 ||
            jsti_private_directory_create(jsti::utf8(target).c_str(), local, sizeof(local)) != 0 ||
            jsti_private_directory_create(jsti::utf8(target + L"\\child").c_str(), local, sizeof(local)) != 0) {
            return fail(local);
        }
        for (const char *invalid : {"..", "relative\\name", "00000000-0000-4000-8000-00000000000:"}) {
            JSTIOwnedCaptureFile *unexpected = nullptr;
            if (jsti_owned_capture_file_create(jsti::utf8(selected).c_str(), invalid, recording,
                                               &unexpected, local, sizeof(local)) == 0 || unexpected || !local[0]) {
                std::unique_ptr<JSTIOwnedCaptureFile> owner(unexpected);
                return fail("Held capture accepted a non-UUID ownership component.");
            }
        }
        JSTIOwnedCaptureFile *raw = nullptr;
        if (jsti_owned_capture_file_create(jsti::utf8(selected).c_str(), directory.c_str(), recording,
                                           &raw, local, sizeof(local)) != 0) return fail(local);
        std::unique_ptr<JSTIOwnedCaptureFile> capture(raw);
        const uint8_t pcm[] = {1, 2, 3, 4};
        const uint8_t patch[] = {9, 8};
        if (jsti_owned_capture_file_write(raw, pcm, sizeof(pcm), local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_seek(raw, 0, local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_write(raw, patch, sizeof(patch), local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_flush(raw, local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_validate(raw, local, sizeof(local)) != 0) return fail(local);
        {
            jsti::Handle permissions;
            permissions.value = CreateFileW(folder.c_str(), WRITE_DAC | READ_CONTROL,
                                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                                              FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (permissions.value == INVALID_HANDLE_VALUE ||
                SetSecurityInfo(permissions.value, SE_FILE_OBJECT,
                                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS) {
                return fail(jsti::systemError("Set synthetic non-private capture ACL"));
            }
            const bool rejected = jsti_owned_capture_file_validate(raw, local, sizeof(local)) != 0 && local[0];
            const DWORD restored = SetSecurityInfo(
                permissions.value, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                nullptr, nullptr, static_cast<PACL>(capture->security.acl.value), nullptr);
            if (restored != ERROR_SUCCESS || !rejected ||
                jsti_owned_capture_file_validate(raw, local, sizeof(local)) != 0) {
                return fail("Held capture did not reject and recover from a synthetic insecure private-leaf ACL.");
            }
        }
        jsti::Handle competing;
        competing.value = CreateFileW(audio.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE |
                                      FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
        if (competing.value != INVALID_HANDLE_VALUE) return fail("Held audio admitted a competing writer.");
        for (const auto &path : {selected, folder, audio}) {
            if (MoveFileW(path.c_str(), (path + L".replacement").c_str())) {
                return fail("A held root, private directory or audio file was renamed.");
            }
        }
        JSTIOwnedCaptureFile *collision = nullptr;
        if (jsti_owned_capture_file_create(jsti::utf8(selected).c_str(), directory.c_str(), recording,
                                           &collision, local, sizeof(local)) == 0 || collision) {
            std::unique_ptr<JSTIOwnedCaptureFile> unexpected(collision);
            return fail("Held capture did not create its UUID directory exclusively.");
        }
        const std::wstring junctionTarget = target.substr(4);
        if (!createTestJunction(junction, junctionTarget, detail)) return fail(detail);
        for (const auto &path : {junction, junction + L"\\child"}) {
            JSTIOwnedCaptureFile *linked = nullptr;
            if (jsti_owned_capture_file_create(jsti::utf8(path).c_str(), directory.c_str(), recording,
                                               &linked, local, sizeof(local)) == 0 || linked) {
                std::unique_ptr<JSTIOwnedCaptureFile> unexpected(linked);
                return fail("Held capture traversed a junction in its root or ancestry.");
            }
        }
        const std::wstring linkedID = L"00000000-0000-4000-8000-000000000004";
        if (!createTestJunction(selected + L"\\" + linkedID, junctionTarget, detail)) return fail(detail);
        JSTIOwnedCaptureFile *linkedLeaf = nullptr;
        if (jsti_owned_capture_file_create(jsti::utf8(selected).c_str(), jsti::utf8(linkedID).c_str(), recording,
                                           &linkedLeaf, local, sizeof(local)) == 0 || linkedLeaf) {
            std::unique_ptr<JSTIOwnedCaptureFile> unexpected(linkedLeaf);
            return fail("An existing UUID junction was treated as a new owned leaf.");
        }
        // Close releases the pins, but retains bytes. Prove the rename failures
        // above were held-handle exclusion, not missing user permissions.
        if (jsti_owned_capture_file_close(raw, local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_close(raw, local, sizeof(local)) != 0) return fail(local);
        for (const auto &path : {audio, folder, selected}) {
            const std::wstring moved = path + L".replacement";
            if (!MoveFileW(path.c_str(), moved.c_str()) || !MoveFileW(moved.c_str(), path.c_str())) {
                return fail(jsti::systemError("Rename released capture fixture"));
            }
        }
        if (jsti_owned_capture_file_write(raw, pcm, sizeof(pcm), local, sizeof(local)) == 0 ||
            jsti_owned_capture_file_seek(raw, 0, local, sizeof(local)) == 0 ||
            jsti_owned_capture_file_flush(raw, local, sizeof(local)) == 0 ||
            jsti_owned_capture_file_validate(raw, local, sizeof(local)) == 0 ||
            jsti_owned_capture_file_discard(raw, local, sizeof(local)) == 0) {
            return fail("A closed capture capability admitted mutation.");
        }
        jsti::Handle reader;
        reader.value = CreateFileW(audio.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE |
                                   FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
        uint8_t bytes[4]{};
        DWORD count = 0;
        if (reader.value == INVALID_HANDLE_VALUE || !ReadFile(reader.value, bytes, 4, &count, nullptr) ||
            count != 4 || bytes[0] != 9 || bytes[1] != 8 || bytes[2] != 3 || bytes[3] != 4) {
            return fail("Held write/seek/flush/close did not preserve the expected bytes.");
        }
        const char *cancelID = "00000000-0000-4000-8000-000000000003";
        JSTIOwnedCaptureFile *cancelled = nullptr;
        if (jsti_owned_capture_file_create(jsti::utf8(selected).c_str(), cancelID, recording,
                                           &cancelled, local, sizeof(local)) != 0) return fail(local);
        std::unique_ptr<JSTIOwnedCaptureFile> cancelOwner(cancelled);
        if (jsti_owned_capture_file_write(cancelled, pcm, sizeof(pcm), local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_discard(cancelled, local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_close(cancelled, local, sizeof(local)) != 0) return fail(local);
        const std::wstring cancelDirectory = selected + L"\\00000000-0000-4000-8000-000000000003";
        const DWORD cancelAttributes = GetFileAttributesW(cancelDirectory.c_str());
        if (GetFileAttributesW((cancelDirectory + L"\\00000000-0000-4000-8000-000000000002.wav").c_str())
                != INVALID_FILE_ATTRIBUTES ||
            cancelAttributes == INVALID_FILE_ATTRIBUTES || !(cancelAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
            GetFileAttributesW(audio.c_str()) == INVALID_FILE_ATTRIBUTES) {
            return fail("Discard removed an unrelated file or failed to keep the empty private directory.");
        }
        return captureResult(true, "", error, capacity);
    } catch (const std::exception &) {
        return jsti::fail("Could not allocate the held-capture native fixture.", error, capacity);
    }
}

namespace {
bool publicationCancelled(jsti_file_publication_cancelled_fn cancelled, void *context) {
    return cancelled && cancelled(context) != 0;
}

int copyForPublication(HANDLE source, HANDLE output, jsti_file_publication_cancelled_fn cancelled,
                       void *context, std::string &error) {
    std::array<BYTE, 64 * 1024> buffer{};
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(source, &size) || size.QuadPart < 0) {
        error = jsti::systemError("Read private export size");
        return -1;
    }
    auto remaining = static_cast<ULONGLONG>(size.QuadPart);
    while (remaining > 0) {
        if (publicationCancelled(cancelled, context)) return 2;
        DWORD count = 0;
        const DWORD requested = static_cast<DWORD>(std::min<ULONGLONG>(remaining, buffer.size()));
        if (!ReadFile(source, buffer.data(), requested, &count, nullptr)) {
            error = jsti::systemError("Read private export source");
            return -1;
        }
        if (!count) {
            error = "The private export source changed while it was being copied.";
            return -1;
        }
        for (DWORD offset = 0; offset < count;) {
            DWORD written = 0;
            if (!WriteFile(output, buffer.data() + offset, count - offset, &written, nullptr) || !written) {
                error = jsti::systemError("Write private export staging");
                return -1;
            }
            offset += written;
        }
        remaining -= count;
    }
    if (publicationCancelled(cancelled, context)) return 2;
    if (!FlushFileBuffers(output)) {
        error = jsti::systemError("Flush private export staging");
        return -1;
    }
    return 0;
}

int publishPrivateFile(const char *sourcePath, const char *destinationPath,
                       jsti_file_publication_cancelled_fn cancelled, void *context,
                       jsti::Handle &output, std::string &error) {
    if (publicationCancelled(cancelled, context)) return 2;
    std::vector<std::wstring> sourceParts, destinationParts;
    std::vector<std::unique_ptr<jsti::Handle>> sourceParents, destinationParents;
    PrivateSecurity security;
    if (!parsePath(sourcePath, sourceParts, error) || !parsePath(destinationPath, destinationParts, error) ||
        !security.initialise(error) || !openParents(sourceParts, sourceParents, error) ||
        !openParents(destinationParts, destinationParents, error)) return -1;
    jsti::Handle source;
    if (!openRelative(sourceParents.back()->value, sourceParts.back(),
                      READ_CONTROL | FILE_READ_DATA | FILE_READ_ATTRIBUTES, FILE_OPEN, false, nullptr,
                      source, error, FILE_SHARE_READ) || !verifyPrivate(source.value, security, error)) return -1;
    FILE_ATTRIBUTE_TAG_INFO attributes{};
    if (!GetFileInformationByHandleEx(source.value, FileAttributeTagInfo, &attributes, sizeof(attributes))) {
        error = jsti::systemError("Inspect private export source");
        return -1;
    }
    if (attributes.FileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) {
        error = "Private export requires a regular, non-reparse source file.";
        return -1;
    }
    GUID guid{};
    wchar_t identifier[40]{};
    if (FAILED(CoCreateGuid(&guid)) || !StringFromGUID2(guid, identifier, static_cast<int>(std::size(identifier)))) {
        error = "Could not create a unique export staging name.";
        return -1;
    }
    const std::wstring name = L".jsti-export-" + std::wstring(identifier) + L".partial";
    if (!openRelative(destinationParents.back()->value, name,
                      READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_WRITE_DATA | DELETE, FILE_CREATE, false,
                      &security.descriptor, output, error, FILE_SHARE_READ) ||
        !verifyPrivate(output.value, security, error)) return -1;
    const int copied = copyForPublication(source.value, output.value, cancelled, context, error);
    if (copied != 0) return copied;
    const std::wstring &target = destinationParts.back();
    const size_t bytes = target.size() * sizeof(wchar_t);
    std::vector<BYTE> storage(std::max(sizeof(FILE_RENAME_INFO), offsetof(FILE_RENAME_INFO, FileName) + bytes), 0);
    auto *rename = reinterpret_cast<FILE_RENAME_INFO *>(storage.data());
    rename->ReplaceIfExists = FALSE;
    rename->RootDirectory = destinationParents.back()->value;
    rename->FileNameLength = static_cast<DWORD>(bytes);
    std::memcpy(rename->FileName, target.data(), bytes);
    if (publicationCancelled(cancelled, context)) return 2;
    // Preserve the held root all the way through rename. The Win32 wrapper
    // rejects this relative-name form on supported Windows hosts.
    // The user-mode SDK omits this export and NT information class 10.
    using SetInformation = NTSTATUS (NTAPI *)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, ULONG);
    static const auto setInformation = [] {
        const HMODULE module = GetModuleHandleW(L"ntdll.dll");
        return module ? reinterpret_cast<SetInformation>(GetProcAddress(module, "NtSetInformationFile")) : nullptr;
    }();
    if (!setInformation) {
        error = "Windows does not provide NtSetInformationFile required for protected backup publication.";
        return -1;
    }
    IO_STATUS_BLOCK status{};
    constexpr ULONG renameInformation = 10;
    const NTSTATUS renamed = setInformation(
        output.value, &status, rename, static_cast<ULONG>(storage.size()), renameInformation);
    if (renamed < 0) {
        error = jsti::systemError("Publish private export without replacing an existing file",
                                  RtlNtStatusToDosError(renamed));
        return -1;
    }
    return 0;
}
} // namespace

int jsti_private_file_publish(const char *source, const char *destination,
                              jsti_file_publication_cancelled_fn cancelled, void *context,
                              char *error, size_t capacity) {
    jsti::Handle output;
    std::string detail;
    int result = -1;
    try {
        result = publishPrivateFile(source, destination, cancelled, context, output, detail);
    } catch (const std::exception &) {
        detail = "Private export could not allocate its publication state.";
    }
    if (result != 0 && output.value && output.value != INVALID_HANDLE_VALUE) {
        FILE_DISPOSITION_INFO disposition{TRUE};
        if (!SetFileInformationByHandle(output.value, FileDispositionInfo, &disposition, sizeof(disposition))) {
            detail += " " + jsti::systemError("Remove partial private export");
            result = -1;
        }
    }
    if (output.value && output.value != INVALID_HANDLE_VALUE) {
        const HANDLE handle = output.value;
        output.value = nullptr;
        if (!CloseHandle(handle)) {
            detail = jsti::systemError("Close private export handle");
            if (result == 0) {
                jsti::fail(detail, error, capacity);
                return 3;
            }
            result = -1;
        }
    }
    if (result < 0) return jsti::fail(detail, error, capacity);
    if (error && capacity) error[0] = 0;
    return result;
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
            if (jsti_private_directory_create(path, localError, sizeof(localError)) != -1 || !localError[0]) {
                return jsti::fail("Private directory creation accepted an unsafe test path.", error, capacity);
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
        paths.exclusiveDirectory = paths.root + L"\\exclusive";
        const std::string root = jsti::utf8(paths.root);
        const std::string file = jsti::utf8(paths.file);
        const std::string exclusive = jsti::utf8(paths.exclusiveDirectory);
        if (jsti_private_directory_create(exclusive.c_str(), localError, sizeof(localError)) != 0) {
            return jsti::fail(localError, error, capacity);
        }
        if (jsti_private_directory_create(exclusive.c_str(), localError, sizeof(localError)) != -1 ||
            !localError[0]) {
            return jsti::fail("Private directory creation accepted an existing directory.", error, capacity);
        }
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
            handle.value = CreateFileW(paths.root.c_str(), READ_CONTROL | WRITE_DAC, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                       nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
            if (handle.value == INVALID_HANDLE_VALUE) {
                return jsti::fail(jsti::systemError("Open test directory for ACL repair"), error, capacity);
            }
            BYTE everyone[SECURITY_MAX_SID_SIZE] = {};
            DWORD sidSize = sizeof(everyone);
            if (!CreateWellKnownSid(WinWorldSid, nullptr, everyone, &sidSize)) {
                return jsti::fail(jsti::systemError("Create synthetic test trustee"), error, capacity);
            }
            EXPLICIT_ACCESSW entry{};
            entry.grfAccessPermissions = FILE_ALL_ACCESS;
            entry.grfAccessMode = GRANT_ACCESS;
            entry.grfInheritance = NO_INHERITANCE;
            BuildTrusteeWithSidW(&entry.Trustee, everyone);
            PACL permissiveACL = nullptr;
            const DWORD aclCode = SetEntriesInAclW(1, &entry, static_cast<PACL>(testSecurity.acl.value), &permissiveACL);
            LocalMemory permissiveMemory;
            permissiveMemory.value = permissiveACL;
            if (aclCode != ERROR_SUCCESS) {
                return jsti::fail(jsti::systemError("Create synthetic directory test ACL", aclCode), error, capacity);
            }
            const DWORD code = SetSecurityInfo(handle.value, SE_FILE_OBJECT,
                                               DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                               nullptr, nullptr, permissiveACL, nullptr);
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
