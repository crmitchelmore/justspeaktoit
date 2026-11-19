#include "WindowsAutomationPipeInternal.hpp"
#include <aclapi.h>
#include <sddl.h>
#include <cstring>

namespace jsti::automation {
namespace {
DWORD integrityLevel(HANDLE token) {
    DWORD size = 0;
    GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    if (!size || !GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), size, &size)) return 0;
    const PSID sid = reinterpret_cast<TOKEN_MANDATORY_LABEL *>(buffer.data())->Label.Sid;
    return *GetSidSubAuthority(sid, static_cast<DWORD>(*GetSidSubAuthorityCount(sid) - 1));
}

DWORD processIntegrity() {
    HANDLE raw = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw)) return SECURITY_MANDATORY_HIGH_RID;
    Handle token(raw);
    return integrityLevel(token.value);
}

bool hasNetworkGroup(HANDLE token) {
    DWORD size = 0;
    GetTokenInformation(token, TokenGroups, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    if (!size || !GetTokenInformation(token, TokenGroups, buffer.data(), size, &size)) return true;
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;
    PSID network = nullptr;
    if (!AllocateAndInitializeSid(&authority, 1, SECURITY_NETWORK_RID, 0, 0, 0, 0, 0, 0, 0, &network)) return true;
    const auto *groups = reinterpret_cast<TOKEN_GROUPS *>(buffer.data());
    bool found = false;
    for (DWORD index = 0; index < groups->GroupCount && !found; ++index) {
        found = (groups->Groups[index].Attributes & SE_GROUP_ENABLED) && EqualSid(groups->Groups[index].Sid, network);
    }
    FreeSid(network);
    return found;
}
} // namespace

std::string utf8(const wchar_t *text) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    if (size <= 1) return {};
    std::string result(static_cast<size_t>(size), 0);
    WideCharToMultiByte(CP_UTF8, 0, text, -1, &result[0], size, nullptr, nullptr);
    result.resize(static_cast<size_t>(size - 1));
    return result;
}

std::vector<BYTE> processUser(DWORD &code) {
    HANDLE raw = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw)) { code = GetLastError(); return {}; }
    Handle token(raw);
    DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    if (!size || !GetTokenInformation(token.value, TokenUser, buffer.data(), size, &size)) {
        code = GetLastError();
        return {};
    }
    const PSID sid = reinterpret_cast<TOKEN_USER *>(buffer.data())->User.Sid;
    std::vector<BYTE> copy(GetLengthSid(sid));
    if (!CopySid(static_cast<DWORD>(copy.size()), copy.data(), sid)) { code = GetLastError(); return {}; }
    return copy;
}

bool pipeSecurity(PSECURITY_DESCRIPTOR &descriptor, DWORD &code) {
    const std::vector<BYTE> user = processUser(code);
    if (user.empty()) return false;
    LPWSTR text = nullptr;
    if (!ConvertSidToStringSidW(const_cast<BYTE *>(user.data()), &text)) { code = GetLastError(); return false; }
    const std::wstring sid(text);
    LocalFree(text);
    const std::wstring sddl = L"O:" + sid + L"D:P(D;;GA;;;NU)(A;;GA;;;" + sid + L")";
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) {
        code = GetLastError();
        return false;
    }
    return true;
}

bool trustedClient(HANDLE pipe) {
    if (!ImpersonateNamedPipeClient(pipe)) return false;
    HANDLE raw = nullptr;
    const BOOL opened = OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &raw);
    RevertToSelf();
    if (!opened) return false;
    Handle token(raw);
    DWORD code = 0;
    const std::vector<BYTE> user = processUser(code);
    DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    if (user.empty() || !size || !GetTokenInformation(token.value, TokenUser, buffer.data(), size, &size)) return false;
    const PSID client = reinterpret_cast<TOKEN_USER *>(buffer.data())->User.Sid;
    return EqualSid(client, const_cast<BYTE *>(user.data())) && !hasNetworkGroup(token.value) &&
        integrityLevel(token.value) >= processIntegrity();
}

} // namespace jsti::automation

using namespace jsti::automation;

int jsti_automation_user_sid(char *sid, size_t capacity, size_t *required, char *error, size_t errorCapacity) {
    DWORD code = 0;
    const std::vector<BYTE> user = processUser(code);
    if (user.empty()) return systemFail(-1, "Read the current user", code, error, errorCapacity);
    LPWSTR text = nullptr;
    if (!ConvertSidToStringSidW(const_cast<BYTE *>(user.data()), &text)) {
        return systemFail(-1, "Format the current user", GetLastError(), error, errorCapacity);
    }
    const std::string value = utf8(text);
    LocalFree(text);
    if (required) *required = value.size() + 1;
    if (!sid || capacity < value.size() + 1) return sid ? 2 : 0;
    std::memcpy(sid, value.c_str(), value.size() + 1);
    return 0;
}

int jsti_automation_pipe_security(JSTIAutomationPipeConnection *connection, char *sddl, size_t capacity,
                                  size_t *required, char *error, size_t errorCapacity) {
    if (!connection || connection->pipe == INVALID_HANDLE_VALUE) {
        return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation connection is closed.", error, errorCapacity);
    }
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    const DWORD code = GetSecurityInfo(connection->pipe, SE_KERNEL_OBJECT,
                                       OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, nullptr, nullptr,
                                       nullptr, nullptr, &descriptor);
    if (code != ERROR_SUCCESS) return systemFail(-1, "Read automation pipe security", code, error, errorCapacity);
    LPWSTR text = nullptr;
    const BOOL converted = ConvertSecurityDescriptorToStringSecurityDescriptorW(
        descriptor, SDDL_REVISION_1, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &text, nullptr);
    LocalFree(descriptor);
    if (!converted) return systemFail(-1, "Format automation pipe security", GetLastError(), error, errorCapacity);
    const std::string value = utf8(text);
    LocalFree(text);
    if (required) *required = value.size() + 1;
    if (!sddl || capacity < value.size() + 1) return sddl ? 2 : 0;
    std::memcpy(sddl, value.c_str(), value.size() + 1);
    return 0;
}
