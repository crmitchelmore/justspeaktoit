#include "WindowsAutomationPipeInternal.hpp"
#include <sddl.h>
#include <cstring>

using namespace jsti::automation;

namespace {
struct ServerProbe {
    JSTIAutomationPipeListener *listener = nullptr;
    int accept = -99, read = -99, write = -99, drain = -99;
    uint8_t received[4] = {};
    std::string sddl;
};

DWORD WINAPI serveOnce(void *context) {
    auto &probe = *static_cast<ServerProbe *>(context);
    JSTIAutomationPipeConnection *connection = nullptr;
    probe.accept = jsti_automation_pipe_accept(probe.listener, &connection, nullptr, 0);
    if (probe.accept != JSTI_AUTOMATION_PIPE_OK) return 0;
    probe.read = jsti_automation_pipe_read(connection, probe.received, 4, 5000, nullptr, 0);
    if (probe.read == JSTI_AUTOMATION_PIPE_OK) {
        char sddl[1024] = {};
        size_t required = 0;
        if (jsti_automation_pipe_security(connection, sddl, sizeof(sddl), &required, nullptr, 0) == 0) probe.sddl = sddl;
        const uint8_t reply[4] = {'p', 'o', 'n', 'g'};
        probe.write = jsti_automation_pipe_write(connection, reply, 4, 5000, nullptr, 0);
        probe.drain = jsti_automation_pipe_drain(connection, 5000);
    }
    jsti_automation_pipe_close(connection);
    return 0;
}

// A thread impersonating this user at low integrity, like a sandboxed process.
// Exit code: 1 setup failed, 2 refused at open or write, 3 wrote but got no
// reply, 4 the server answered it.
DWORD WINAPI lowIntegrityClient(void *context) {
    auto *name = static_cast<const char *>(context);
    HANDLE process = nullptr, duplicate = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY, &process)) return 1;
    Handle owned(process);
    if (!DuplicateTokenEx(process, TOKEN_ALL_ACCESS, nullptr, SecurityImpersonation, TokenImpersonation, &duplicate)) {
        return 1;
    }
    Handle token(duplicate);
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_MANDATORY_LABEL_AUTHORITY;
    PSID low = nullptr;
    if (!AllocateAndInitializeSid(&authority, 1, SECURITY_MANDATORY_LOW_RID, 0, 0, 0, 0, 0, 0, 0, &low)) return 1;
    TOKEN_MANDATORY_LABEL label{};
    label.Label.Attributes = SE_GROUP_INTEGRITY;
    label.Label.Sid = low;
    const BOOL lowered = SetTokenInformation(duplicate, TokenIntegrityLevel, &label,
                                             static_cast<DWORD>(sizeof(label) + GetLengthSid(low)));
    FreeSid(low);
    if (!lowered || !SetThreadToken(nullptr, duplicate)) return 1;
    JSTIAutomationPipeConnection *connection = nullptr;
    DWORD outcome = 2;
    if (jsti_automation_pipe_connect(name, 2000, &connection, nullptr, 0) == JSTI_AUTOMATION_PIPE_OK) {
        const uint8_t request[4] = {'l', 'o', 'w', '!'};
        if (jsti_automation_pipe_write(connection, request, 4, 2000, nullptr, 0) == JSTI_AUTOMATION_PIPE_OK) {
            outcome = 3;
            uint8_t reply[4] = {};
            if (jsti_automation_pipe_read(connection, reply, 4, 2000, nullptr, 0) == JSTI_AUTOMATION_PIPE_OK) outcome = 4;
        }
        jsti_automation_pipe_close(connection);
    }
    RevertToSelf();
    return outcome;
}

// Compares SIDs rather than SDDL text, which abbreviates well-known accounts
// (SYSTEM is "SY") and may render access masks differently.
bool ownedByUserAlone(const std::string &sddl) {
    DWORD code = 0;
    const std::vector<BYTE> user = processUser(code);
    const std::wstring wide(sddl.begin(), sddl.end());
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (user.empty() || !ConvertStringSecurityDescriptorToSecurityDescriptorW(wide.c_str(), SDDL_REVISION_1,
                                                                               &descriptor, nullptr)) {
        return false;
    }
    std::unique_ptr<void, decltype(&LocalFree)> owned(descriptor, &LocalFree);
    PSID userSid = const_cast<BYTE *>(user.data());
    PSID owner = nullptr;
    BOOL defaulted = FALSE, present = FALSE;
    PACL dacl = nullptr;
    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    if (!GetSecurityDescriptorOwner(descriptor, &owner, &defaulted) || !owner || !EqualSid(owner, userSid) ||
        !GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted) || !present || !dacl ||
        !GetSecurityDescriptorControl(descriptor, &control, &revision) || !(control & SE_DACL_PROTECTED) ||
        dacl->AceCount != 2) {
        return false;
    }
    BYTE networkBuffer[SECURITY_MAX_SID_SIZE] = {};
    DWORD networkSize = sizeof(networkBuffer);
    if (!CreateWellKnownSid(WinNetworkSid, nullptr, networkBuffer, &networkSize)) return false;
    bool deniesNetwork = false, allowsUser = false;
    for (DWORD index = 0; index < dacl->AceCount; ++index) {
        void *raw = nullptr;
        if (!GetAce(dacl, index, &raw)) return false;
        const auto *header = static_cast<ACE_HEADER *>(raw);
        if (header->AceType == ACCESS_DENIED_ACE_TYPE) {
            auto *ace = static_cast<ACCESS_DENIED_ACE *>(raw);
            deniesNetwork = deniesNetwork || EqualSid(reinterpret_cast<PSID>(&ace->SidStart), networkBuffer);
        } else if (header->AceType == ACCESS_ALLOWED_ACE_TYPE) {
            auto *ace = static_cast<ACCESS_ALLOWED_ACE *>(raw);
            allowsUser = allowsUser || EqualSid(reinterpret_cast<PSID>(&ace->SidStart), userSid);
        } else {
            return false;
        }
    }
    return deniesNetwork && allowsUser;
}

std::string exchangeFailure(const std::string &name, ServerProbe &probe) {
    HANDLE server = CreateThread(nullptr, 0, serveOnce, &probe, 0, nullptr);
    if (!server) return "Could not start the automation self-test server.";
    JSTIAutomationPipeConnection *client = nullptr;
    uint8_t reply[4] = {};
    const uint8_t request[4] = {'p', 'i', 'n', 'g'};
    std::string failure;
    if (jsti_automation_pipe_connect(name.c_str(), 5000, &client, nullptr, 0) != JSTI_AUTOMATION_PIPE_OK ||
        jsti_automation_pipe_write(client, request, 4, 5000, nullptr, 0) != JSTI_AUTOMATION_PIPE_OK ||
        jsti_automation_pipe_read(client, reply, 4, 5000, nullptr, 0) != JSTI_AUTOMATION_PIPE_OK ||
        std::memcmp(reply, "pong", 4) != 0) {
        failure = "The automation pipe did not carry one request and reply.";
    }
    if (client) jsti_automation_pipe_close(client);
    WaitForSingleObject(server, 10000);
    CloseHandle(server);
    if (!failure.empty()) return failure;
    if (probe.read != JSTI_AUTOMATION_PIPE_OK || std::memcmp(probe.received, "ping", 4) != 0 ||
        probe.write != JSTI_AUTOMATION_PIPE_OK || probe.drain != JSTI_AUTOMATION_PIPE_OK) {
        return "The automation server did not read, answer and drain one client.";
    }
    if (!ownedByUserAlone(probe.sddl)) {
        return "The automation pipe's owner or access list is not this user alone: " + probe.sddl;
    }
    return {};
}
} // namespace

int jsti_automation_pipe_self_test(char *error, size_t capacity) {
    char sid[256] = {};
    size_t required = 0;
    if (jsti_automation_user_sid(sid, sizeof(sid), &required, error, capacity) != 0) return -1;
    const std::string leaf = "JustSpeakToIt-selftest-" + std::to_string(GetCurrentProcessId()) + "-" +
        std::to_string(GetTickCount64());
    const std::string name = "\\\\.\\pipe\\" + leaf;
    const char *nonLocal[] = {"\\\\server\\pipe\\speak", "\\\\.\\pipe\\a\\b", "speak", "\\\\.\\pipe\\"};
    for (const char *candidate : nonLocal) {
        JSTIAutomationPipeListener *refused = nullptr;
        JSTIAutomationPipeConnection *remote = nullptr;
        const bool listened = jsti_automation_pipe_listen(candidate, 1, &refused, nullptr, 0) == JSTI_AUTOMATION_PIPE_OK;
        const bool opened = jsti_automation_pipe_connect(candidate, 10, &remote, nullptr, 0) == JSTI_AUTOMATION_PIPE_OK;
        if (refused) jsti_automation_pipe_listener_release(refused);
        if (remote) jsti_automation_pipe_close(remote);
        if (listened || opened) {
            return fail(-1, "The automation pipe accepted a name outside this computer's pipe namespace.", error,
                        capacity);
        }
    }
    JSTIAutomationPipeConnection *missing = nullptr;
    if (jsti_automation_pipe_connect(name.c_str(), 10, &missing, nullptr, 0) != JSTI_AUTOMATION_PIPE_NOT_FOUND) {
        if (missing) jsti_automation_pipe_close(missing);
        return fail(-1, "Connecting to a missing automation pipe was not reported as not running.", error, capacity);
    }
    JSTIAutomationPipeListener *listener = nullptr;
    if (jsti_automation_pipe_listen(name.c_str(), 2, &listener, error, capacity) != JSTI_AUTOMATION_PIPE_OK) return -1;
    std::string failure;
    JSTIAutomationPipeListener *second = nullptr;
    if (jsti_automation_pipe_listen(name.c_str(), 2, &second, nullptr, 0) != JSTI_AUTOMATION_PIPE_IN_USE) {
        failure = "A second listener was allowed on an owned automation pipe.";
    }
    if (second) jsti_automation_pipe_listener_release(second);
    ServerProbe probe;
    probe.listener = listener;
    if (failure.empty()) failure = exchangeFailure(name, probe);
    if (failure.empty()) {
        const std::wstring redirected = L"\\\\localhost\\pipe\\" + std::wstring(leaf.begin(), leaf.end());
        HANDLE through = CreateFileW(redirected.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                                     SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
        if (through != INVALID_HANDLE_VALUE) {
            CloseHandle(through);
            failure = "The automation pipe accepted a client through the network redirector.";
        }
    }
    if (failure.empty()) {
        ServerProbe lowProbe;
        lowProbe.listener = listener;
        HANDLE lowServer = CreateThread(nullptr, 0, serveOnce, &lowProbe, 0, nullptr);
        HANDLE low = CreateThread(nullptr, 0, lowIntegrityClient, const_cast<char *>(name.c_str()), 0, nullptr);
        DWORD outcome = 1;
        if (low) {
            WaitForSingleObject(low, 10000);
            GetExitCodeThread(low, &outcome);
            CloseHandle(low);
        }
        // Unblocks the server when the low-integrity client never connected.
        jsti_automation_pipe_stop(listener, 5000);
        if (lowServer) {
            WaitForSingleObject(lowServer, 10000);
            CloseHandle(lowServer);
        }
        if (outcome == 1) failure = "Could not create the low-integrity automation client.";
        else if (outcome == 4 || (outcome == 3 && lowProbe.read != JSTI_AUTOMATION_PIPE_UNTRUSTED)) {
            failure = "The automation pipe served a low-integrity client.";
        }
    }
    if (failure.empty()) {
        // A stopped listener refuses new clients at once, and stopping again is harmless.
        JSTIAutomationPipeConnection *late = nullptr;
        if (jsti_automation_pipe_stop(listener, 5000) != JSTI_AUTOMATION_PIPE_OK ||
            jsti_automation_pipe_accept(listener, &late, nullptr, 0) != JSTI_AUTOMATION_PIPE_CANCELLED || late ||
            jsti_automation_pipe_wait_for_stop(listener, 0) != 1) {
            failure = "A stopped automation listener still accepted clients.";
        }
        if (late) jsti_automation_pipe_close(late);
    }
    jsti_automation_pipe_listener_release(listener);
    if (!failure.empty()) return fail(-1, failure, error, capacity);
    if (error && capacity) error[0] = 0;
    return 0;
}
