#include "include/CWindowsSupport.h"
// Lean windows.h first (it leaves out winsock.h), then Winsock 2 and DNS.
#include "WindowsSupportInternal.hpp"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windns.h>
#include <new>
#include <string>
#include <vector>

// Send from phone (F46): the receiver's Winsock listener and connections, and
// its DNS-SD announcement through Windows' own mDNS responder. The protocol,
// pairing and encryption are shared Swift (DesktopTransportReceiver); this
// file only moves bytes and announces the port.

struct JSTITransportListener {
    SOCKET socket = INVALID_SOCKET;
};

struct JSTITransportConnection {
    SOCKET socket = INVALID_SOCKET;
};

namespace {
std::string socketError(const char *operation) { return jsti::systemError(operation, WSAGetLastError()); }

bool startSockets() {
    WSADATA data{};
    return WSAStartup(MAKEWORD(2, 2), &data) == 0;
}

// 1 readable, 0 timed out, -1 failed.
int waitReadable(SOCKET socket, int timeout) {
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(socket, &readable);
    timeval wait{};
    wait.tv_sec = timeout < 0 ? 0 : timeout / 1000;
    wait.tv_usec = timeout < 0 ? 0 : (timeout % 1000) * 1000;
    const int ready = select(0, &readable, nullptr, nullptr, &wait);
    if (ready > 0) return 1;
    return ready == 0 ? 0 : -1;
}

SOCKET bindListening(int family, bool loopbackOnly) {
    SOCKET socket = ::socket(family, SOCK_STREAM, IPPROTO_TCP);
    if (socket == INVALID_SOCKET) return INVALID_SOCKET;
    BOOL exclusive = TRUE;
    setsockopt(socket, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char *>(&exclusive),
               sizeof(exclusive));
    int bound = SOCKET_ERROR;
    if (family == AF_INET6) {
        DWORD v6Only = 0;
        setsockopt(socket, IPPROTO_IPV6, IPV6_V6ONLY, reinterpret_cast<const char *>(&v6Only), sizeof(v6Only));
        sockaddr_in6 address{};
        address.sin6_family = AF_INET6;
        address.sin6_addr = in6addr_any;
        bound = bind(socket, reinterpret_cast<sockaddr *>(&address), sizeof(address));
    } else {
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(loopbackOnly ? INADDR_LOOPBACK : INADDR_ANY);
        bound = bind(socket, reinterpret_cast<sockaddr *>(&address), sizeof(address));
    }
    if (bound != 0 || listen(socket, 16) != 0) {
        closesocket(socket);
        return INVALID_SOCKET;
    }
    return socket;
}

JSTITransportConnection *adopt(SOCKET socket) {
    if (!startSockets()) {
        closesocket(socket);
        return nullptr;
    }
    auto *connection = new (std::nothrow) JSTITransportConnection();
    if (!connection) {
        closesocket(socket);
        WSACleanup();
        return nullptr;
    }
    connection->socket = socket;
    BOOL noDelay = TRUE;
    setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char *>(&noDelay), sizeof(noDelay));
    DWORD sendTimeout = 5000;
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char *>(&sendTimeout), sizeof(sendTimeout));
    return connection;
}
} // namespace

JSTITransportListener *jsti_transport_listen(int loopbackOnly, uint16_t *boundPort, char *error, size_t capacity) {
    if (!startSockets()) {
        jsti::fail("Windows Sockets could not start.", error, capacity);
        return nullptr;
    }
    SOCKET socket = loopbackOnly ? INVALID_SOCKET : bindListening(AF_INET6, false);
    if (socket == INVALID_SOCKET) socket = bindListening(AF_INET, loopbackOnly != 0);
    if (socket == INVALID_SOCKET) {
        jsti::fail(socketError("Opening a port for phones"), error, capacity);
        WSACleanup();
        return nullptr;
    }
    sockaddr_storage bound{};
    int length = sizeof(bound);
    if (getsockname(socket, reinterpret_cast<sockaddr *>(&bound), &length) != 0) {
        jsti::fail(socketError("Reading the port for phones"), error, capacity);
        closesocket(socket);
        WSACleanup();
        return nullptr;
    }
    auto *listener = new (std::nothrow) JSTITransportListener();
    if (!listener) {
        closesocket(socket);
        WSACleanup();
        jsti::fail("Out of memory.", error, capacity);
        return nullptr;
    }
    listener->socket = socket;
    const u_short port = bound.ss_family == AF_INET6 ? reinterpret_cast<sockaddr_in6 *>(&bound)->sin6_port
                                                     : reinterpret_cast<sockaddr_in *>(&bound)->sin_port;
    if (boundPort) *boundPort = ntohs(port);
    return listener;
}

int jsti_transport_accept(JSTITransportListener *listener, int timeout, JSTITransportConnection **connection) {
    if (!listener || listener->socket == INVALID_SOCKET || !connection) return -1;
    *connection = nullptr;
    const int ready = waitReadable(listener->socket, timeout);
    if (ready <= 0) return ready;
    SOCKET peer = accept(listener->socket, nullptr, nullptr);
    if (peer == INVALID_SOCKET) {
        // The phone gave up between the readiness signal and the accept, or
        // the process is out of sockets for now: keep listening.
        const int code = WSAGetLastError();
        return code == WSAECONNRESET || code == WSAEWOULDBLOCK || code == WSAEMFILE || code == WSAENOBUFS ? 0 : -1;
    }
    *connection = adopt(peer);
    return *connection ? 1 : 0;
}

void jsti_transport_listener_destroy(JSTITransportListener *listener) {
    if (!listener) return;
    if (listener->socket != INVALID_SOCKET) closesocket(listener->socket);
    delete listener;
    WSACleanup();
}

JSTITransportConnection *jsti_transport_connect_loopback(uint16_t port) {
    if (!startSockets()) return nullptr;
    SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    JSTITransportConnection *connection = nullptr;
    if (socket != INVALID_SOCKET &&
        connect(socket, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0) {
        connection = adopt(socket);
    } else if (socket != INVALID_SOCKET) {
        closesocket(socket);
    }
    WSACleanup();
    return connection;
}

int jsti_transport_read(JSTITransportConnection *connection, uint8_t *buffer, int capacity, int timeout) {
    if (!connection || connection->socket == INVALID_SOCKET || !buffer || capacity <= 0) return -1;
    const int ready = waitReadable(connection->socket, timeout);
    if (ready <= 0) return ready;
    const int received = recv(connection->socket, reinterpret_cast<char *>(buffer), capacity, 0);
    if (received > 0) return received;
    if (received < 0 && WSAGetLastError() == WSAEWOULDBLOCK) return 0;
    return -1;
}

int jsti_transport_write(JSTITransportConnection *connection, const uint8_t *bytes, size_t count) {
    if (!connection || connection->socket == INVALID_SOCKET || (!bytes && count)) return -1;
    size_t sent = 0;
    while (sent < count) {
        const int chunk = static_cast<int>(std::min<size_t>(count - sent, 64 * 1024));
        const int written = send(connection->socket, reinterpret_cast<const char *>(bytes + sent), chunk, 0);
        if (written <= 0) return -1;
        sent += static_cast<size_t>(written);
    }
    return 0;
}

void jsti_transport_connection_destroy(JSTITransportConnection *connection) {
    if (!connection) return;
    if (connection->socket != INVALID_SOCKET) {
        shutdown(connection->socket, SD_SEND);
        char scratch[512];
        const ULONGLONG until = GetTickCount64() + 200;
        while (GetTickCount64() < until && waitReadable(connection->socket, 50) > 0) {
            if (recv(connection->socket, scratch, sizeof(scratch), 0) <= 0) break;
        }
        closesocket(connection->socket);
    }
    delete connection;
    WSACleanup();
}

int jsti_transport_self_test(char *error, size_t capacity) {
    uint16_t port = 0;
    JSTITransportListener *listener = jsti_transport_listen(1, &port, error, capacity);
    if (!listener) return -1;
    std::string failure;
    JSTITransportConnection *client = jsti_transport_connect_loopback(port);
    JSTITransportConnection *server = nullptr;
    if (!client || jsti_transport_accept(listener, 2000, &server) != 1 || !server) {
        failure = "Send from phone: a loopback connection was not accepted.";
    } else {
        const uint8_t hello[] = {'p', 'i', 'n', 'g'};
        uint8_t received[16] = {};
        if (jsti_transport_read(server, received, sizeof(received), 0) != 0) {
            failure = "Send from phone: an idle connection did not time out.";
        } else if (jsti_transport_write(client, hello, sizeof(hello)) != 0 ||
                   jsti_transport_read(server, received, sizeof(received), 2000) != static_cast<int>(sizeof(hello)) ||
                   std::memcmp(received, hello, sizeof(hello)) != 0) {
            failure = "Send from phone: bytes did not reach the receiver.";
        } else if (jsti_transport_write(server, hello, sizeof(hello)) != 0 ||
                   jsti_transport_read(client, received, sizeof(received), 2000) != static_cast<int>(sizeof(hello))) {
            failure = "Send from phone: the receiver's reply did not reach the phone.";
        } else {
            jsti_transport_connection_destroy(client);
            client = nullptr;
            if (jsti_transport_read(server, received, sizeof(received), 2000) != -1) {
                failure = "Send from phone: a closed connection was not reported.";
            }
        }
    }
    jsti_transport_connection_destroy(client);
    jsti_transport_connection_destroy(server);
    jsti_transport_listener_destroy(listener);
    if (!failure.empty()) return jsti::fail(failure, error, capacity);
    char ignored[64];
    if (jsti_dns_service_register("", "_speaktransport._tcp", 1, ignored, sizeof(ignored)) ||
        jsti_dns_service_register("Desktop", "_speaktransport._tcp", 0, ignored, sizeof(ignored))) {
        return jsti::fail("Send from phone: an announcement without a name or port was accepted.", error, capacity);
    }
    return 0;
}

// ---- DNS-SD ----------------------------------------------------------------

namespace {
using ConstructInstance = PDNS_SERVICE_INSTANCE(WINAPI *)(PCWSTR, PCWSTR, PIP4_ADDRESS, PIP6_ADDRESS, WORD, WORD,
                                                          WORD, DWORD, PCWSTR *, PCWSTR *);
using FreeInstance = VOID(WINAPI *)(PDNS_SERVICE_INSTANCE);
using Register = DWORD(WINAPI *)(PDNS_SERVICE_REGISTER_REQUEST, PDNS_SERVICE_CANCEL);
using DeRegister = DWORD(WINAPI *)(PDNS_SERVICE_REGISTER_REQUEST, PDNS_SERVICE_CANCEL);

struct DnsFunctions {
    ConstructInstance construct = nullptr;
    FreeInstance free = nullptr;
    Register registerService = nullptr;
    DeRegister deregister = nullptr;
};

// Loaded at run time: the DNS-SD functions arrived in Windows 10 1903.
const DnsFunctions *dnsFunctions() {
    static const DnsFunctions functions = [] {
        DnsFunctions loaded;
        HMODULE module = LoadLibraryExW(L"dnsapi.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module) return loaded;
        loaded.construct =
            reinterpret_cast<ConstructInstance>(GetProcAddress(module, "DnsServiceConstructInstance"));
        loaded.free = reinterpret_cast<FreeInstance>(GetProcAddress(module, "DnsServiceFreeInstance"));
        loaded.registerService = reinterpret_cast<Register>(GetProcAddress(module, "DnsServiceRegister"));
        loaded.deregister = reinterpret_cast<DeRegister>(GetProcAddress(module, "DnsServiceDeRegister"));
        return loaded;
    }();
    return functions.construct && functions.free && functions.registerService && functions.deregister
        ? &functions : nullptr;
}

// Windows calls back once a registration or deregistration completes.
void CALLBACK registered(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance);
} // namespace

struct JSTIDnsService {
    DNS_SERVICE_REGISTER_REQUEST request{};
    PDNS_SERVICE_INSTANCE instance = nullptr;
    HANDLE completed = nullptr;
    DWORD status = ERROR_IO_PENDING;
};

namespace {
void CALLBACK registered(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance) {
    auto *service = static_cast<JSTIDnsService *>(context);
    if (instance) {
        if (const DnsFunctions *functions = dnsFunctions()) functions->free(instance);
    }
    service->status = status;
    SetEvent(service->completed);
}

// Waits for Windows' callback; false when it did not come in time.
bool awaitCallback(JSTIDnsService &service) {
    return WaitForSingleObject(service.completed, 5000) == WAIT_OBJECT_0;
}

void freeService(JSTIDnsService *service) {
    if (service->instance) dnsFunctions()->free(service->instance);
    if (service->completed) CloseHandle(service->completed);
    delete service;
}
} // namespace

JSTIDnsService *jsti_dns_service_register(const char *name, const char *type, uint16_t port, char *error,
                                          size_t capacity) {
    std::wstring instanceName, serviceType;
    if (!name || !*name || !type || !*type || !port || !jsti::wide(name, instanceName) ||
        !jsti::wide(type, serviceType)) {
        jsti::fail("A service name, type and port are required.", error, capacity);
        return nullptr;
    }
    const DnsFunctions *functions = dnsFunctions();
    if (!functions) {
        jsti::fail("Phones cannot find this PC: announcing it needs Windows 10 version 1903 or later.", error,
                   capacity);
        return nullptr;
    }
    // Instance names are single DNS labels: dots would split them.
    for (auto &character : instanceName) if (character == L'.') character = L'-';
    wchar_t computer[256] = {};
    DWORD computerLength = 256;
    if (!GetComputerNameExW(ComputerNamePhysicalDnsHostname, computer, &computerLength) || !computerLength) {
        jsti::fail(jsti::systemError("Reading this PC's network name"), error, capacity);
        return nullptr;
    }
    const std::wstring fullName = instanceName + L"." + serviceType + L".local";
    const std::wstring hostName = std::wstring(computer, computerLength) + L".local";
    auto *service = new (std::nothrow) JSTIDnsService();
    if (!service) {
        jsti::fail("Out of memory.", error, capacity);
        return nullptr;
    }
    service->completed = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    service->instance =
        functions->construct(fullName.c_str(), hostName.c_str(), nullptr, nullptr, port, 0, 0, 0, nullptr, nullptr);
    if (!service->completed || !service->instance) {
        jsti::fail(jsti::systemError("Preparing the announcement for phones"), error, capacity);
        freeService(service);
        return nullptr;
    }
    service->request.Version = DNS_QUERY_REQUEST_VERSION1;
    service->request.InterfaceIndex = 0;
    service->request.pServiceInstance = service->instance;
    service->request.pRegisterCompletionCallback = registered;
    service->request.pQueryContext = service;
    service->request.unicastEnabled = FALSE;
    const DWORD started = functions->registerService(&service->request, nullptr);
    if (started != DNS_REQUEST_PENDING) {
        jsti::fail(jsti::systemError("Announcing this PC to phones", started), error, capacity);
        freeService(service);
        return nullptr;
    }
    if (!awaitCallback(*service)) {
        // Windows still holds the request; it is withdrawn, and the
        // registration is leaked rather than freed under a late callback.
        functions->deregister(&service->request, nullptr);
        jsti::fail("Windows did not confirm the announcement for phones in time.", error, capacity);
        return nullptr;
    }
    if (service->status != ERROR_SUCCESS) {
        jsti::fail(jsti::systemError("Announcing this PC to phones", service->status), error, capacity);
        freeService(service);
        return nullptr;
    }
    return service;
}

void jsti_dns_service_unregister(JSTIDnsService *service) {
    if (!service) return;
    service->status = ERROR_IO_PENDING;
    if (dnsFunctions()->deregister(&service->request, nullptr) == DNS_REQUEST_PENDING && !awaitCallback(*service)) {
        return; // A late callback still uses it: leaked, never freed under it.
    }
    freeService(service);
}
