// jsti_private_storage_self_test: private staging, publication and junction refusal.
#include "CWindowsSelfTest.h"
#include "../CWindowsSupport/WindowsFileSecurityInternal.hpp"

using namespace jsti_file_security;

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
