#ifndef JSTI_WINDOWS_NETWORK_H
#define JSTI_WINDOWS_NETWORK_H
/* WebSocket and CloudKit sync: HTTPS, loopback sign-in, envelope crypto and the iCloud dialog. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JSTIWebSocket JSTIWebSocket;
enum JSTIWebSocketEvent {
    JSTI_WEBSOCKET_OPEN = 1,
    JSTI_WEBSOCKET_TEXT = 2,
    JSTI_WEBSOCKET_BINARY = 3,
    JSTI_WEBSOCKET_SEND_COMPLETE = 4,
    JSTI_WEBSOCKET_CLOSED = 5,
    JSTI_WEBSOCKET_ERROR = 6
};
/* All callbacks run serially on one dedicated worker. Bytes are borrowed until
 * return; copy synchronously. Messages are complete and bounded to 4 MiB. Code
 * is the native error for ERROR/SEND_COMPLETE (zero means send succeeded), or
 * the peer close status for CLOSED. Error bytes never include URL/header data.
 * Callbacks may send or cancel, but must not destroy this socket. */
typedef void (*JSTIWebSocketCallback)(int event, const uint8_t *bytes, size_t count,
                                     int code, void *context);
/* Copies all inputs. wss is required except ws on literal loopback addresses
 * or localhost for local probes. Credentials in URLs and redirects are refused.
 * Header names/values are validated; WinHTTP owns the upgrade control headers. */
JSTIWebSocket *jsti_websocket_create(const char *url, const char *const *header_names,
                                     const char *const *header_values, size_t header_count,
                                     JSTIWebSocketCallback callback, void *context,
                                     char *error, size_t error_capacity);
int jsti_websocket_start(JSTIWebSocket *socket, char *error, size_t error_capacity);
/* Copies at most 4 MiB. Exactly one send may be outstanding. A return of zero
 * guarantees one later SEND_COMPLETE callback, including during cancellation. */
int jsti_websocket_send(JSTIWebSocket *socket, const uint8_t *bytes, size_t count,
                        int is_text, char *error, size_t error_capacity);
/* Thread safe cancellation, including during the HTTP upgrade. No join. */
void jsti_websocket_cancel(JSTIWebSocket *socket);
/* Serialize destruction against all caller API calls. Cancels, drains native
 * callbacks and joins the worker. On failure the socket/context remain owned
 * by the caller and must be retained; zero releases the socket permanently. */
int jsti_websocket_destroy(JSTIWebSocket *socket, char *error, size_t error_capacity);
/* Deterministic URL/header validation; no network or credentials. */
int jsti_websocket_self_test(char *error, size_t error_capacity);

/* ---- CloudKit sync -------------------------------------------------------- */

/* One HTTPS request through WinHTTP, for CloudKit Web Services. Blocking: call
 * perform from a worker thread. https is required except http to the literal
 * loopback address or localhost (local fake servers). Redirects, cookies,
 * credentials in the URL and automatic authentication are refused; responses
 * are never cached. headers is "Name: value" lines joined by CRLF, or NULL.
 * The URL and headers carry tokens: they are never copied into errors.
 * perform returns 0 with *status set, 1 when cancelled, 2 when the body exceeds
 * response_limit, 3 on timeout, 4 on a transient connection failure, and -1
 * on any other failure. After 0, body/headers stay valid until destroy. */
typedef struct JSTIHTTPRequest JSTIHTTPRequest;
JSTIHTTPRequest *jsti_http_request_create(void);
int jsti_http_request_perform(JSTIHTTPRequest *request, const char *method, const char *url,
                              const char *headers, const uint8_t *body, size_t body_count,
                              size_t response_limit, int timeout_milliseconds, int *status,
                              char *error, size_t error_capacity);
/* The response body and the raw CRLF-separated response headers (UTF-8). */
const uint8_t *jsti_http_request_body(const JSTIHTTPRequest *request, size_t *count);
const char *jsti_http_request_headers(const JSTIHTTPRequest *request);
/* Thread safe; a blocked perform returns 1 promptly. */
void jsti_http_request_cancel(JSTIHTTPRequest *request);
/* Never while perform runs on another thread. */
void jsti_http_request_destroy(JSTIHTTPRequest *request);

/* A one-connection-at-a-time HTTP listener on 127.0.0.1, for the Apple ID
 * sign-in callback and for loopback test servers. port 0 picks a free port.
 * accept waits up to timeout for one complete request (at most 1 MiB):
 * 0 success, 1 timeout, 3 cancelled, -1 failure. A connection that closes, or
 * sends no complete request within request_window_milliseconds (0: five
 * seconds), is dropped and listening goes on. respond writes raw bytes and
 * closes the connection. */
typedef struct JSTILoopbackListener JSTILoopbackListener;
typedef struct JSTILoopbackConnection JSTILoopbackConnection;
JSTILoopbackListener *jsti_loopback_listen(uint16_t port, int request_window_milliseconds, uint16_t *bound_port,
                                           char *error, size_t error_capacity);
int jsti_loopback_accept(JSTILoopbackListener *listener, int timeout_milliseconds,
                         JSTILoopbackConnection **connection, char *error, size_t error_capacity);
const uint8_t *jsti_loopback_request(const JSTILoopbackConnection *connection, size_t *count);
/* Who owns the socket at the other end, from the TCP table's owning process:
 * 0 a process of this process's user, 1 another user's, -1 when that cannot
 * be determined (including a process this user may not open). Only while the
 * peer's socket is open. */
int jsti_loopback_peer_owner(const JSTILoopbackConnection *connection);
int jsti_loopback_respond(JSTILoopbackConnection *connection, const uint8_t *bytes, size_t count);
void jsti_loopback_connection_destroy(JSTILoopbackConnection *connection);
/* Thread safe; a blocked accept returns 3 promptly. */
void jsti_loopback_cancel(JSTILoopbackListener *listener);
void jsti_loopback_destroy(JSTILoopbackListener *listener);

/* CNG primitives for the API-key sync envelope: PBKDF2-HMAC-SHA256, and
 * AES-256-GCM with a fresh random 96-bit nonce, no associated data and a
 * 128-bit tag kept apart from the ciphertext. open returns 1 when the tag does
 * not verify. All return -1 on other failures. */
int jsti_crypto_pbkdf2_sha256(const uint8_t *password, size_t password_count, const uint8_t *salt,
                              size_t salt_count, uint64_t iterations, uint8_t *key, size_t key_count,
                              char *error, size_t error_capacity);
int jsti_crypto_aes_gcm_seal(const uint8_t *key, size_t key_count, const uint8_t *plaintext, size_t count,
                             uint8_t *nonce12, uint8_t *ciphertext, uint8_t *tag16,
                             char *error, size_t error_capacity);
int jsti_crypto_aes_gcm_open(const uint8_t *key, size_t key_count, const uint8_t *nonce12,
                             const uint8_t *ciphertext, size_t count, const uint8_t *tag16,
                             uint8_t *plaintext, char *error, size_t error_capacity);
int jsti_crypto_random(uint8_t *bytes, size_t count, char *error, size_t error_capacity);

/* Opens an https URL on an apple.com or icloud.com host in the default browser. */
int jsti_shell_open_sign_in_page(const char *url, char *error, size_t error_capacity);

/* The iCloud sync dialog (Settings menu). The host supplies a snapshot; the
 * dialog closes after one action and calls back on the UI thread with it:
 * 1 apply choices, 2 sign in, 3 sign out, 4 sync now. passphrase is the typed
 * API-key passphrase (empty when none) and is wiped when the callback returns.
 * Thread safe; the context is borrowed like jsti_window_set_voice_output's. */
typedef struct JSTICloudSyncView {
    const char *status;
    int available;
    int signed_in;
    int history_enabled;
    int key_import_enabled;
} JSTICloudSyncView;
typedef void (*JSTICloudSyncCallback)(int action, int history_enabled, int key_import_enabled,
                                      const char *passphrase, void *context);
int jsti_window_set_cloud_sync(const JSTICloudSyncView *view, JSTICloudSyncCallback callback, void *context);
void jsti_window_clear_cloud_sync(void);

#ifdef __cplusplus
}
#endif
#endif
