#include "include/CWindowsSupport.h"
// Lean windows.h first (it leaves out winsock.h), then Winsock 2.
#include "WindowsSupportInternal.hpp"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <cstddef>
#include <cstdlib>
#include <new>
#include <mutex>
#include <string>
#include <vector>

// A minimal HTTP/1.1 listener bound to 127.0.0.1 only. It serves one
// connection at a time: the Apple ID sign-in callback, or a loopback fake
// server in tests. Nothing outside this machine can connect to it, and each
// connection can report which user's process opened it.

struct JSTILoopbackListener {
    std::mutex mutex;
    SOCKET socket = INVALID_SOCKET;
    WSAEVENT cancelEvent = WSA_INVALID_EVENT;
    bool started = false;
};

struct JSTILoopbackConnection {
    SOCKET socket = INVALID_SOCKET;
    std::vector<uint8_t> request;
};

namespace {
constexpr size_t requestLimit = 1024 * 1024;

std::string socketError(const char *operation) { return jsti::systemError(operation, WSAGetLastError()); }

// Bytes a complete request needs once its header block is known, or 0.
size_t expectedLength(const std::vector<uint8_t> &bytes) {
    const char *begin = reinterpret_cast<const char *>(bytes.data());
    const std::string text(begin, bytes.size());
    const size_t end = text.find("\r\n\r\n");
    if (end == std::string::npos) return 0;
    size_t length = 0;
    size_t line = text.find("\r\n");
    while (line != std::string::npos && line < end) {
        const size_t next = text.find("\r\n", line + 2);
        std::string header = text.substr(line + 2, (next == std::string::npos ? end : next) - line - 2);
        for (auto &character : header) {
            if (character >= 'A' && character <= 'Z') character = static_cast<char>(character - 'A' + 'a');
        }
        if (header.rfind("content-length:", 0) == 0) length = std::strtoull(header.c_str() + 15, nullptr, 10);
        line = next;
    }
    return end + 4 + length;
}

// Waits until the socket is ready or the listener is cancelled: 0 ready,
// 1 timeout, 3 cancelled, -1 failure.
int waitFor(JSTILoopbackListener &listener, SOCKET socket, long events, DWORD timeout) {
    WSAEVENT ready = WSACreateEvent();
    if (ready == WSA_INVALID_EVENT) return -1;
    int result = -1;
    if (WSAEventSelect(socket, ready, events) == 0) {
        WSAEVENT handles[2] = {ready, listener.cancelEvent};
        const DWORD signalled = WSAWaitForMultipleEvents(2, handles, FALSE, timeout, FALSE);
        if (signalled == WSA_WAIT_EVENT_0) result = 0;
        else if (signalled == WSA_WAIT_EVENT_0 + 1) result = 3;
        else if (signalled == WSA_WAIT_TIMEOUT) result = 1;
        WSAEventSelect(socket, nullptr, 0);
    }
    WSACloseEvent(ready);
    u_long blocking = 0;
    ioctlsocket(socket, FIONBIO, &blocking);
    return result;
}

// A process's user SID, copied out of its token; empty when unreadable.
std::vector<BYTE> tokenUser(HANDLE process) {
    jsti::Handle token;
    if (!OpenProcessToken(process, TOKEN_QUERY, &token.value)) return {};
    DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    if (!size) return {};
    std::vector<BYTE> buffer(size);
    if (!GetTokenInformation(token.value, TokenUser, buffer.data(), size, &size)) return {};
    const PSID sid = reinterpret_cast<TOKEN_USER *>(buffer.data())->User.Sid;
    if (!sid || !IsValidSid(sid)) return {};
    std::vector<BYTE> copy(GetLengthSid(sid));
    if (!CopySid(static_cast<DWORD>(copy.size()), copy.data(), sid)) return {};
    return copy;
}

// 0 when the process runs as `user`, 1 as another account, -1 when that
// cannot be read: another account's process usually cannot be opened.
int processOwner(DWORD processID, const std::vector<BYTE> &user) {
    if (processID == GetCurrentProcessId()) return 0;
    if (processID == 0) return -1;
    jsti::Handle process;
    process.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processID);
    if (!process.value) return -1;
    std::vector<BYTE> owner = tokenUser(process.value);
    if (owner.empty()) return -1;
    return EqualSid(owner.data(), const_cast<BYTE *>(user.data())) ? 0 : 1;
}

// One address family's TCP connections with their owning processes, or
// empty when the table cannot be read.
std::vector<uint8_t> tcpTable(ULONG family) {
    std::vector<uint8_t> buffer;
    for (int attempt = 0; attempt < 4; ++attempt) {
        DWORD size = static_cast<DWORD>(buffer.size());
        const DWORD result = GetExtendedTcpTable(buffer.empty() ? nullptr : buffer.data(), &size, FALSE, family,
                                                 TCP_TABLE_OWNER_PID_ALL, 0);
        if (result == NO_ERROR && !buffer.empty()) return buffer;
        if (result != ERROR_INSUFFICIENT_BUFFER || !size) return {};
        buffer.assign(size, 0);
    }
    return {};
}

// The rows of a table buffer, bounded by the buffer: nullptr when it is
// shorter than its entry count says.
template<class Table, class Row> const Row *tableRows(const std::vector<uint8_t> &buffer, DWORD &count) {
    count = 0;
    const size_t offset = offsetof(Table, table);
    if (buffer.size() < offset) return nullptr;
    const auto *table = reinterpret_cast<const Table *>(buffer.data());
    if (table->dwNumEntries > (buffer.size() - offset) / sizeof(Row)) return nullptr;
    count = table->dwNumEntries;
    return table->table;
}

bool isMapped(const UCHAR address[16], const in_addr &ipv4) {
    static const UCHAR prefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF};
    return std::memcmp(address, prefix, sizeof(prefix)) == 0 && std::memcmp(address + 12, &ipv4, 4) == 0;
}
} // namespace

JSTILoopbackListener *jsti_loopback_listen(uint16_t port, uint16_t *boundPort, char *error, size_t capacity) {
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
        jsti::fail("Windows Sockets could not start.", error, capacity);
        return nullptr;
    }
    auto *listener = new (std::nothrow) JSTILoopbackListener();
    if (!listener) { WSACleanup(); jsti::fail("Out of memory.", error, capacity); return nullptr; }
    listener->started = true;
    listener->cancelEvent = WSACreateEvent();
    listener->socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL exclusive = TRUE;
    if (listener->cancelEvent == WSA_INVALID_EVENT || listener->socket == INVALID_SOCKET ||
        setsockopt(listener->socket, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char *>(&exclusive),
                   sizeof(exclusive)) != 0 ||
        bind(listener->socket, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 ||
        listen(listener->socket, 4) != 0) {
        jsti::fail(socketError("Listening on the loopback address"), error, capacity);
        jsti_loopback_destroy(listener);
        return nullptr;
    }
    sockaddr_in bound{};
    int length = sizeof(bound);
    if (getsockname(listener->socket, reinterpret_cast<sockaddr *>(&bound), &length) != 0) {
        jsti::fail(socketError("Reading the loopback port"), error, capacity);
        jsti_loopback_destroy(listener);
        return nullptr;
    }
    if (boundPort) *boundPort = ntohs(bound.sin_port);
    return listener;
}

int jsti_loopback_accept(JSTILoopbackListener *listener, int timeout, JSTILoopbackConnection **connection,
                         char *error, size_t capacity) {
    if (!listener || !connection) return jsti::fail("Invalid loopback request.", error, capacity);
    *connection = nullptr;
    const DWORD wait = timeout < 0 ? WSA_INFINITE : static_cast<DWORD>(timeout);
    const ULONGLONG deadline = GetTickCount64() + (timeout < 0 ? 0 : static_cast<ULONGLONG>(timeout));
    const int accepted = waitFor(*listener, listener->socket, FD_ACCEPT, wait);
    if (accepted != 0) {
        if (accepted < 0) jsti::fail(socketError("Waiting for a loopback connection"), error, capacity);
        return accepted;
    }
    SOCKET peer = accept(listener->socket, nullptr, nullptr);
    if (peer == INVALID_SOCKET) return jsti::fail(socketError("Accepting a loopback connection"), error, capacity);
    auto *result = new (std::nothrow) JSTILoopbackConnection();
    if (!result) { closesocket(peer); return jsti::fail("Out of memory.", error, capacity); }
    result->socket = peer;
    char buffer[16 * 1024];
    for (;;) {
        const size_t expected = expectedLength(result->request);
        if (expected && result->request.size() >= expected) break;
        if (result->request.size() > requestLimit) {
            jsti_loopback_connection_destroy(result);
            return jsti::fail("The loopback request is too large.", error, capacity);
        }
        const ULONGLONG now = GetTickCount64();
        const DWORD remaining = timeout < 0 ? WSA_INFINITE : (now >= deadline ? 0 : static_cast<DWORD>(deadline - now));
        const int readable = waitFor(*listener, peer, FD_READ | FD_CLOSE, remaining);
        if (readable != 0) {
            jsti_loopback_connection_destroy(result);
            if (readable < 0) jsti::fail(socketError("Reading a loopback request"), error, capacity);
            return readable;
        }
        const int received = recv(peer, buffer, sizeof(buffer), 0);
        if (received <= 0) {
            jsti_loopback_connection_destroy(result);
            return jsti::fail("The loopback connection closed before its request was complete.", error, capacity);
        }
        result->request.insert(result->request.end(), buffer, buffer + received);
    }
    *connection = result;
    return 0;
}

const uint8_t *jsti_loopback_request(const JSTILoopbackConnection *connection, size_t *count) {
    if (count) *count = connection ? connection->request.size() : 0;
    return connection && !connection->request.empty() ? connection->request.data() : nullptr;
}

// The socket at the other end is listed in the TCP table with its owning
// process: the row whose local end is the peer's address and port and whose
// remote end is this listener's. A dual-stack socket may list 127.0.0.1 as
// ::ffff:127.0.0.1. TIME_WAIT rows belong to no process. No row, or an owner
// that cannot be read, is unknown.
int jsti_loopback_peer_owner(const JSTILoopbackConnection *connection) {
    if (!connection || connection->socket == INVALID_SOCKET) return -1;
    sockaddr_in peer{};
    sockaddr_in local{};
    int peerLength = sizeof(peer);
    int localLength = sizeof(local);
    if (getpeername(connection->socket, reinterpret_cast<sockaddr *>(&peer), &peerLength) != 0 ||
        peer.sin_family != AF_INET ||
        getsockname(connection->socket, reinterpret_cast<sockaddr *>(&local), &localLength) != 0 ||
        local.sin_family != AF_INET) {
        return -1;
    }
    constexpr DWORD timeWait = MIB_TCP_STATE_TIME_WAIT;
    std::vector<DWORD> owners;
    DWORD count = 0;
    const std::vector<uint8_t> four = tcpTable(AF_INET);
    const auto *rows = tableRows<MIB_TCPTABLE_OWNER_PID, MIB_TCPROW_OWNER_PID>(four, count);
    for (DWORD index = 0; rows && index < count; ++index) {
        const MIB_TCPROW_OWNER_PID &row = rows[index];
        if (row.dwState != timeWait && row.dwLocalAddr == peer.sin_addr.s_addr &&
            static_cast<u_short>(row.dwLocalPort) == peer.sin_port && row.dwRemoteAddr == local.sin_addr.s_addr &&
            static_cast<u_short>(row.dwRemotePort) == local.sin_port) {
            owners.push_back(row.dwOwningPid);
        }
    }
    const std::vector<uint8_t> six = tcpTable(AF_INET6);
    const auto *rows6 = tableRows<MIB_TCP6TABLE_OWNER_PID, MIB_TCP6ROW_OWNER_PID>(six, count);
    for (DWORD index = 0; rows6 && index < count; ++index) {
        const MIB_TCP6ROW_OWNER_PID &row = rows6[index];
        if (row.dwState != timeWait && isMapped(row.ucLocalAddr, peer.sin_addr) &&
            static_cast<u_short>(row.dwLocalPort) == peer.sin_port && isMapped(row.ucRemoteAddr, local.sin_addr) &&
            static_cast<u_short>(row.dwRemotePort) == local.sin_port) {
            owners.push_back(row.dwOwningPid);
        }
    }
    if (owners.empty()) return -1;
    const std::vector<BYTE> user = tokenUser(GetCurrentProcess());
    if (user.empty()) return -1;
    int result = 0;
    for (const DWORD processID : owners) {
        const int owner = processOwner(processID, user);
        if (owner < 0) return -1;
        if (owner > 0) result = 1;
    }
    return result;
}

int jsti_loopback_respond(JSTILoopbackConnection *connection, const uint8_t *bytes, size_t count) {
    if (!connection || connection->socket == INVALID_SOCKET || (!bytes && count)) return -1;
    size_t sent = 0;
    while (sent < count) {
        const int chunk = static_cast<int>(std::min<size_t>(count - sent, 64 * 1024));
        const int written = send(connection->socket, reinterpret_cast<const char *>(bytes + sent), chunk, 0);
        if (written <= 0) return -1;
        sent += static_cast<size_t>(written);
    }
    shutdown(connection->socket, SD_SEND);
    return 0;
}

void jsti_loopback_connection_destroy(JSTILoopbackConnection *connection) {
    if (!connection) return;
    if (connection->socket != INVALID_SOCKET) closesocket(connection->socket);
    if (!connection->request.empty()) SecureZeroMemory(connection->request.data(), connection->request.size());
    delete connection;
}

void jsti_loopback_cancel(JSTILoopbackListener *listener) {
    if (!listener) return;
    std::lock_guard<std::mutex> lock(listener->mutex);
    if (listener->cancelEvent != WSA_INVALID_EVENT) WSASetEvent(listener->cancelEvent);
}

void jsti_loopback_destroy(JSTILoopbackListener *listener) {
    if (!listener) return;
    {
        std::lock_guard<std::mutex> lock(listener->mutex);
        if (listener->socket != INVALID_SOCKET) closesocket(listener->socket);
        if (listener->cancelEvent != WSA_INVALID_EVENT) WSACloseEvent(listener->cancelEvent);
        listener->socket = INVALID_SOCKET;
        listener->cancelEvent = WSA_INVALID_EVENT;
    }
    const bool started = listener->started;
    delete listener;
    if (started) WSACleanup();
}
