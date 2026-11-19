#ifndef JSTI_LINUX_CLOUD_SYNC_H
#define JSTI_LINUX_CLOUD_SYNC_H
/* iCloud sync: window state, the API-key envelope crypto and the loopback sign-in listener. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The window's iCloud sync group reports these on the GTK main thread. */
enum {
    /* Apply. index: bit 0 Sync History, bit 1 Import API keys; text: the
     * passphrase as typed ("" when none), cleared from its entry once sent. */
    JSTI_EVENT_CLOUD_SYNC_APPLY = 60,
    JSTI_EVENT_CLOUD_SYNC_SIGN_IN = 61,
    JSTI_EVENT_CLOUD_SYNC_SIGN_OUT = 62,
    JSTI_EVENT_CLOUD_SYNC_NOW = 63
};

typedef struct JSTICloudSyncView {
    const char *status;
    int32_t available;
    int32_t signed_in;
    int32_t history_enabled;
    int32_t key_import_enabled;
} JSTICloudSyncView;

/* Shows sync state in the iCloud sync group. Until the first call, and while
 * `available` is 0, none of its actions can be used. A switch follows the
 * state only when that value changed, so a refresh keeps unapplied choices.
 * Safe from any thread, like jsti_window_update. */
int32_t jsti_window_set_cloud_sync(const JSTICloudSyncView *view);

/* OpenSSL (libcrypto) primitives for the API-key sync envelope, the same ones
 * CNG provides on Windows: PBKDF2-HMAC-SHA256, and AES-256-GCM with a fresh
 * random 96-bit nonce, no associated data and a 128-bit tag kept apart from
 * the ciphertext. open returns 1 when the tag does not verify, and releases no
 * plaintext then. All return -1 on other failures. */
int32_t jsti_crypto_pbkdf2_sha256(
    const uint8_t *password, size_t password_count, const uint8_t *salt, size_t salt_count, uint64_t iterations,
    uint8_t *key, size_t key_count, char *error, size_t error_capacity);
int32_t jsti_crypto_aes_gcm_seal(
    const uint8_t *key, size_t key_count, const uint8_t *plaintext, size_t count, uint8_t *nonce12,
    uint8_t *ciphertext, uint8_t *tag16, char *error, size_t error_capacity);
int32_t jsti_crypto_aes_gcm_open(
    const uint8_t *key, size_t key_count, const uint8_t *nonce12, const uint8_t *ciphertext, size_t count,
    const uint8_t *tag16, uint8_t *plaintext, char *error, size_t error_capacity);
int32_t jsti_crypto_random(uint8_t *bytes, size_t count, char *error, size_t error_capacity);

/* A 127.0.0.1-only HTTP/1.1 listener, for the Apple ID sign-in callback and
 * loopback fake servers in tests; port 0 picks a free port. It serves one
 * connection at a time. A connection that closes, or sends no complete request
 * (at most 1 MiB) within `request_window_ms` (0: five seconds), is dropped and
 * listening goes on. accept returns 0 with a connection, 1 once
 * `timeout_milliseconds` (-1: none) passes, 3 once cancelled and -1 on failure.
 * cancel is safe from any thread; destroy only after every accept returned. */
typedef struct jsti_loopback jsti_loopback;
typedef struct jsti_loopback_connection jsti_loopback_connection;
jsti_loopback *jsti_loopback_listen(
    uint16_t port, int32_t request_window_ms, uint16_t *bound_port, char *error, size_t error_capacity);
int32_t jsti_loopback_accept(
    jsti_loopback *listener, int32_t timeout_milliseconds, jsti_loopback_connection **connection, char *error,
    size_t error_capacity);
/* The complete request, valid until the connection is destroyed. */
const uint8_t *jsti_loopback_request(const jsti_loopback_connection *connection, size_t *count);
/* Who owns the socket at the other end, from /proc/net/tcp and tcp6: 0 a
 * process of this (effective) user, 1 another user's, -1 when that cannot be
 * determined. Only while the peer's socket is open. */
int32_t jsti_loopback_peer_owner(const jsti_loopback_connection *connection);
/* The same decision over given table texts (either may be NULL), for tests:
 * addresses as in sin_addr.s_addr, ports in host order. */
int32_t jsti_loopback_peer_owner_in_tables(
    const char *tcp, const char *tcp6, uint32_t peer_address, uint16_t peer_port, uint32_t local_address,
    uint16_t local_port, uint32_t user);
/* Writes a complete response and ends the connection's sending side. */
int32_t jsti_loopback_respond(jsti_loopback_connection *connection, const uint8_t *bytes, size_t count);
/* Closes the connection and wipes its request. */
void jsti_loopback_connection_destroy(jsti_loopback_connection *connection);
void jsti_loopback_cancel(jsti_loopback *listener);
void jsti_loopback_destroy(jsti_loopback *listener);

/* Opens an https page on apple.com or icloud.com (or a subdomain) in the
 * default browser, through the OpenURI portal inside Flatpak. Any other
 * address is refused. */
int32_t jsti_open_sign_in_page(const char *url, char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
