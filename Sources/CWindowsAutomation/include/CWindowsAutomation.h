#ifndef JSTI_WINDOWS_AUTOMATION_H
#define JSTI_WINDOWS_AUTOMATION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Same-user local automation transport for the `speak` CLI, its MCP server and
 * the app, over Windows named pipes. A separate target from CWindowsSupport so
 * the thin CLI links only kernel32/advapi32. UTF-8 strings. Every call blocks
 * only its calling thread and is bounded by the timeout it is given; never call
 * from a UI thread. Error text never contains request or reply bytes.
 *
 * Only this machine's pipe namespace (\\.\pipe\name) is accepted; a name that
 * addresses another computer is refused before any I/O. */
enum JSTIAutomationPipeStatus {
    JSTI_AUTOMATION_PIPE_OK = 0,
    JSTI_AUTOMATION_PIPE_FAILED = -1,
    /* Nothing is listening: the app is closed or automation is off. */
    JSTI_AUTOMATION_PIPE_NOT_FOUND = -2,
    /* The pipe exists but this user may not open it. */
    JSTI_AUTOMATION_PIPE_ACCESS_DENIED = -3,
    JSTI_AUTOMATION_PIPE_TIMED_OUT = -4,
    /* The peer closed its end. */
    JSTI_AUTOMATION_PIPE_CLOSED = -5,
    /* The listener was stopped. */
    JSTI_AUTOMATION_PIPE_CANCELLED = -6,
    /* Another process already owns this pipe name. */
    JSTI_AUTOMATION_PIPE_IN_USE = -7,
    /* The peer is not this user, not local, or (a client) below the app's
     * integrity level; nothing is exchanged with it. */
    JSTI_AUTOMATION_PIPE_UNTRUSTED = -8
};

typedef struct JSTIAutomationPipeListener JSTIAutomationPipeListener;
typedef struct JSTIAutomationPipeConnection JSTIAutomationPipeConnection;

/* The process user's string SID (S-1-5-21-...). required includes the NUL;
 * pass null/0 to query it. Returns 0, 2 when the buffer is too small, or -1. */
int jsti_automation_user_sid(char *sid, size_t capacity, size_t *required, char *error, size_t error_capacity);

/* Creates the first instance of pipe_name with FILE_FLAG_FIRST_PIPE_INSTANCE,
 * PIPE_REJECT_REMOTE_CLIENTS and a protected DACL: this user is the owner and
 * the only grantee, network logons are denied, and nobody else - administrators
 * and SYSTEM included - has an entry. IN_USE when another process already owns
 * the name, so the app never serves on a name someone else created. At most
 * max_instances (1-64) clients are served at once; later clients wait. */
int jsti_automation_pipe_listen(const char *pipe_name, uint32_t max_instances,
                                JSTIAutomationPipeListener **listener, char *error, size_t error_capacity);
/* Blocks until a client connects (0), the listener stops (CANCELLED) or an
 * error occurs. Event-driven, never polling. A listening instance stays
 * available while connections are served, so a busy app is never reported as
 * closed. Call from one accept thread only. */
int jsti_automation_pipe_accept(JSTIAutomationPipeListener *listener, JSTIAutomationPipeConnection **connection,
                                char *error, size_t error_capacity);
/* Waits up to timeout_ms for the listener to stop: 1 stopped, 0 still running.
 * Lets an accept thread back off after a failure without polling. */
int jsti_automation_pipe_wait_for_stop(JSTIAutomationPipeListener *listener, uint32_t timeout_ms);
/* Thread safe and idempotent. Stops accepting, aborts pending I/O on every
 * server connection and closes every pipe instance, waiting up to timeout_ms
 * for in-progress I/O to acknowledge. Returns 0 once no instance remains open,
 * so the name can be listened on again, or TIMED_OUT. Connection objects stay
 * valid; their later I/O returns CANCELLED until they are closed. */
int jsti_automation_pipe_stop(JSTIAutomationPipeListener *listener, uint32_t timeout_ms);
/* Stops, then releases the listener. Shared state lives until the last
 * connection closes. Join the accept thread first: never call while accept
 * runs. */
void jsti_automation_pipe_listener_release(JSTIAutomationPipeListener *listener);

/* Client: opens pipe_name, waiting up to timeout_ms while every instance is
 * busy. Opens with identification-level impersonation only and requires the
 * pipe to be owned by this user (UNTRUSTED otherwise), so a process of another
 * account that squats the name can neither act as this user nor receive a
 * request. NOT_FOUND when nothing listens. */
int jsti_automation_pipe_connect(const char *pipe_name, uint32_t timeout_ms,
                                 JSTIAutomationPipeConnection **connection, char *error, size_t error_capacity);

/* Reads exactly count bytes within timeout_ms. On a server connection the first
 * bytes also identify the client - the same user, not a network logon, and at
 * least the app's integrity level - before anything is returned (UNTRUSTED).
 * CLOSED when the peer closes first. One read or write at a time per
 * connection. */
int jsti_automation_pipe_read(JSTIAutomationPipeConnection *connection, uint8_t *bytes, size_t count,
                              uint32_t timeout_ms, char *error, size_t error_capacity);
/* Writes every byte within timeout_ms. CLOSED when the peer has gone. */
int jsti_automation_pipe_write(JSTIAutomationPipeConnection *connection, const uint8_t *bytes, size_t count,
                               uint32_t timeout_ms, char *error, size_t error_capacity);
/* Server: waits up to timeout_ms for the client to read everything and close
 * its end, so disconnecting cannot discard an unread reply. A bounded
 * replacement for FlushFileBuffers, which can block forever on a stalled
 * client. Returns 0 once the client closed, TIMED_OUT or CANCELLED. */
int jsti_automation_pipe_drain(JSTIAutomationPipeConnection *connection, uint32_t timeout_ms);
/* The pipe's owner and DACL as SDDL, as this connection sees them. required
 * includes the NUL; returns 0, 2 when the buffer is too small, or a status. */
int jsti_automation_pipe_security(JSTIAutomationPipeConnection *connection, char *sddl, size_t capacity,
                                  size_t *required, char *error, size_t error_capacity);
/* Disconnects a server connection, closes the handle and frees the object. */
void jsti_automation_pipe_close(JSTIAutomationPipeConnection *connection);

/* Writes UTF-8 text to the console behind stdout (1) or stderr (2) with
 * WriteConsoleW, so transcripts render correctly whatever the console code
 * page, which is never changed. Returns 1 when written to a console, 0 when the
 * stream is redirected (write the bytes unchanged instead), or -1. */
int jsti_automation_console_write(int stream, const char *utf8, size_t count);

/* Deterministic checks on a unique synthetic pipe: the exact owner/DACL, IN_USE
 * for a second listener, refusal of a same-user low-integrity (sandboxed)
 * client, refusal of the same pipe reached through the network redirector, and
 * refusal of non-local names. No request data, credentials or user files. */
int jsti_automation_pipe_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
