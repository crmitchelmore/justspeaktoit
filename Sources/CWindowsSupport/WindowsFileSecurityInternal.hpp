// Private-file security primitives shared by the CWindowsSupport storage units:
// owner/DACL construction and verification, handle-relative path walking, and the
// fixtures their native self-tests use. Never exported from the C ABI.
#pragma once
#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <aclapi.h>
#include <winternl.h>
#include <winioctl.h>
#include <objbase.h>
#include <array>
#include <exception>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

namespace jsti_file_security {
using HeldRootSetInformation = NTSTATUS (NTAPI *)(HANDLE, PIO_STATUS_BLOCK, PVOID, ULONG, ULONG);
constexpr ULONG heldRootRenameInformationClass = 10;

HeldRootSetInformation heldRootSetInformation();

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
        return initialiseFromToken(token.value, error);
    }

    bool initialiseFromToken(HANDLE token, std::string &error, DWORD *nativeError = nullptr, bool formatError = true) {
        auto failed = [&](const char *operation, DWORD code) {
            if (nativeError) *nativeError = code;
            if (formatError) error = jsti::systemError(operation, code);
            return false;
        };
        DWORD size = 0;
        GetTokenInformation(token, TokenUser, nullptr, 0, &size);
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || !size) {
            return failed("GetTokenInformation size", GetLastError());
        }
        user.resize(size);
        if (!GetTokenInformation(token, TokenUser, user.data(), size, &size)) {
            return failed("GetTokenInformation", GetLastError());
        }
        DWORD systemSize = sizeof(system);
        if (!CreateWellKnownSid(WinLocalSystemSid, nullptr, system, &systemSize)) {
            return failed("CreateWellKnownSid", GetLastError());
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
            return failed("SetEntriesInAcl", code);
        }
        if (!InitializeSecurityDescriptor(&descriptor, SECURITY_DESCRIPTOR_REVISION) ||
            !SetSecurityDescriptorOwner(&descriptor, userSID(), FALSE) ||
            !SetSecurityDescriptorDacl(&descriptor, TRUE, result, FALSE) ||
            !SetSecurityDescriptorControl(&descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED)) {
            return failed("Create private security descriptor", GetLastError());
        }
        return true;
    }
};

bool parsePath(const char *utf8, std::vector<std::wstring> &components, std::string &error);
bool checkDirectory(HANDLE handle, std::string &error);
bool openRelative(HANDLE parent, const std::wstring &name, ACCESS_MASK access,
                  ULONG disposition, bool directory, PSECURITY_DESCRIPTOR security,
                  jsti::Handle &result, std::string &error,
                  ULONG sharing = FILE_SHARE_READ | FILE_SHARE_WRITE);
// Retains every ancestor without delete sharing; see WindowsFileSecurity.cpp.
bool openParents(const std::vector<std::wstring> &components,
                 std::vector<std::unique_ptr<jsti::Handle>> &parents, std::string &error);
bool verifyOwner(HANDLE handle, const PrivateSecurity &security, std::string &error);

enum class PrivateDescriptorCheck { valid, descriptor, entryRead, entry, account, missing };
PrivateDescriptorCheck privateDescriptorCheck(PSID owner, PACL acl, PSECURITY_DESCRIPTOR descriptor,
                                               const PrivateSecurity &security, DWORD &nativeError);
bool verifyPrivate(HANDLE handle, const PrivateSecurity &security, std::string &error);
int prepareDirectory(const char *path, char *error, size_t capacity);

bool captureUUID(const char *value, std::wstring &result, std::string &error); // WindowsOwnedCaptureFile.cpp
bool publicationCancelled(jsti_file_publication_cancelled_fn cancelled, void *context); // ...Publication.cpp
bool registryName(const char *value, std::wstring &name, std::string &error); // WindowsRecordingRegistry.cpp

// Self-test fixtures: a real junction (no symbolic-link privilege needed) and
// temporary paths removed in reverse creation order.
bool createTestJunction(const std::wstring &path, const std::wstring &target, std::string &error);
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
} // namespace jsti_file_security
