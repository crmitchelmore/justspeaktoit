#ifndef JSTI_WINDOWS_PHONE_RECEIVER_H
#define JSTI_WINDOWS_PHONE_RECEIVER_H
/* Send from phone: the receiver's TCP listener, its DNS-SD announcement and
 * its Settings dialog. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A Winsock TCP listener on an ephemeral port on every interface (dual-stack,
 * or IPv4 when IPv6 is unavailable). Only one thread uses a listener or a
 * connection at a time. */
typedef struct JSTITransportListener JSTITransportListener;
typedef struct JSTITransportConnection JSTITransportConnection;

/* loopback_only binds 127.0.0.1 for self-tests. */
JSTITransportListener *jsti_transport_listen(int loopback_only, uint16_t *bound_port, char *error, size_t capacity);
/* 1 with a connection, 0 when the wait timed out, -1 once the listener failed. */
int jsti_transport_accept(JSTITransportListener *listener, int timeout_milliseconds,
                          JSTITransportConnection **connection);
void jsti_transport_listener_destroy(JSTITransportListener *listener);
/* A client connection to 127.0.0.1:port, for self-tests. */
JSTITransportConnection *jsti_transport_connect_loopback(uint16_t port);
/* Bytes read (> 0), 0 when the wait timed out, -1 once the peer closed or the read failed. */
int jsti_transport_read(JSTITransportConnection *connection, uint8_t *buffer, int capacity, int timeout_milliseconds);
/* 0 once every byte is sent, -1 when the connection failed. */
int jsti_transport_write(JSTITransportConnection *connection, const uint8_t *bytes, size_t count);
/* Half-closes, briefly drains so the peer reads the last bytes, then closes and frees. */
void jsti_transport_connection_destroy(JSTITransportConnection *connection);
/* Listens, connects, exchanges bytes both ways and closes on loopback. */
int jsti_transport_self_test(char *error, size_t capacity);

/* Announces `name` as a `type` (such as "_speaktransport._tcp") service on
 * `port` through Windows' own mDNS responder (DnsServiceRegister, Windows 10
 * 1903 and later). Waits up to five seconds for Windows to confirm. Returns
 * NULL with a reason when it cannot. */
typedef struct JSTIDnsService JSTIDnsService;
JSTIDnsService *jsti_dns_service_register(const char *name, const char *type, uint16_t port, char *error,
                                          size_t capacity);
/* Withdraws the announcement and frees it. */
void jsti_dns_service_unregister(JSTIDnsService *service);

/* The Send from phone dialog, opened from Settings > iCloud Sync. The host
 * hands it a snapshot; each action calls back on the UI thread. */
typedef struct JSTIPhoneReceiverView {
    const char *status;
    /* Six digits, or "" while the receiver is off. */
    const char *pairing_code;
    /* 0 when the receiver could not start at all; status says why. */
    int32_t available;
    int32_t enabled;
    int32_t device_count;
    const char *const *device_ids;
    const char *const *device_names;
} JSTIPhoneReceiverView;
enum {
    /* value: 1 turns receiving on, 0 off. */
    JSTI_PHONE_RECEIVER_ENABLE = 1,
    JSTI_PHONE_RECEIVER_NEW_CODE = 2,
    /* device_id: the paired device to forget. */
    JSTI_PHONE_RECEIVER_FORGET = 3
};
typedef void (*JSTIPhoneReceiverCallback)(int action, int value, const char *device_id, void *context);
/* Copies everything. Safe from any thread; an open dialog shows it at once. */
int jsti_window_set_phone_receiver(const JSTIPhoneReceiverView *view, JSTIPhoneReceiverCallback callback,
                                   void *context);
/* Closes the dialog's link to the host before the host's context goes away. */
void jsti_window_clear_phone_receiver(void);

#ifdef __cplusplus
}
#endif
#endif
