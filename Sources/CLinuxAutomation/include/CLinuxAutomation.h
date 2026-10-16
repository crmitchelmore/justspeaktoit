#ifndef JSTI_LINUX_AUTOMATION_H
#define JSTI_LINUX_AUTOMATION_H
#include <stddef.h>
#include <stdint.h>

typedef struct JSTIAutomationListener JSTIAutomationListener;
typedef struct JSTIAutomationConnection JSTIAutomationConnection;
enum {
    JSTI_AUTOMATION_OK = 0, JSTI_AUTOMATION_CANCELLED = 1,
    JSTI_AUTOMATION_TIMEOUT = 2, JSTI_AUTOMATION_UNAVAILABLE = 3,
    JSTI_AUTOMATION_UNSAFE = 4, JSTI_AUTOMATION_IO = 5
};
uint32_t jsti_automation_uid(void);
/* Pure admission policies, also used by the production stat/getsockopt paths. */
int jsti_automation_peer_allowed(uint32_t peer_uid);
int jsti_automation_private_metadata(uint32_t owner, uint32_t mode, int directory);
uint64_t jsti_automation_deadline(uint32_t milliseconds);
int jsti_automation_listen(const char *path, JSTIAutomationListener **output);
int jsti_automation_accept(JSTIAutomationListener *listener, JSTIAutomationConnection **output);
/* Interrupts accept and every connection, without closing/reusing their descriptors. */
void jsti_automation_stop(JSTIAutomationListener *listener);
/* Revalidates the anchored root/socket identity; caller retains the listener. */
int jsti_automation_listener_status(JSTIAutomationListener *listener);
/* Call only after accept and every connection worker have joined. */
void jsti_automation_release(JSTIAutomationListener *listener);
int jsti_automation_connect(const char *path, uint64_t deadline, JSTIAutomationConnection **output);
int jsti_automation_read(JSTIAutomationConnection *connection, void *bytes, size_t count, uint64_t deadline);
int jsti_automation_write(JSTIAutomationConnection *connection, const void *bytes, size_t count, uint64_t deadline);
void jsti_automation_close(JSTIAutomationConnection *connection);
#endif
