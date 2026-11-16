#ifndef JSTI_LINUX_PHONE_RECEIVER_H
#define JSTI_LINUX_PHONE_RECEIVER_H
/* Send from phone: the receiver's Settings group and its DNS-SD announcement
 * through Avahi. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The window's Send from phone group reports these on the GTK main thread. */
enum {
    /* index: 1 turns the receiver on, 0 off. */
    JSTI_EVENT_PHONE_RECEIVER_ENABLE = 64,
    JSTI_EVENT_PHONE_RECEIVER_NEW_CODE = 65,
    /* text: the paired device's identifier. */
    JSTI_EVENT_PHONE_RECEIVER_FORGET = 66
};

typedef struct JSTIPhoneReceiverView {
    const char *status;
    /* Six digits, or "" while the receiver is off. */
    const char *pairing_code;
    /* 0 until the receiver is configured, or when it cannot run at all. */
    int32_t available;
    int32_t enabled;
    int32_t device_count;
    const char *const *device_ids;
    const char *const *device_names;
} JSTIPhoneReceiverView;

/* Shows the receiver's state; copies everything. Safe from any thread, like
 * jsti_window_update. */
int32_t jsti_window_set_phone_receiver(const JSTIPhoneReceiverView *view);

/* Announces `name` as a `type` (such as "_speaktransport._tcp") service on
 * `port` on every interface through avahi-daemon on the system bus, and waits
 * up to five seconds for Avahi's probe. When the name is taken, on this
 * computer or by another host, Avahi's alternative ("Name #2") is used and
 * written to `announced` (which may be NULL). Returns NULL with a reason when
 * Avahi cannot be reached or cannot publish. A clash after the probe has
 * succeeded is not re-resolved. Blocks on D-Bus; call it off the GTK thread. */
typedef struct jsti_dnssd jsti_dnssd;
jsti_dnssd *jsti_dnssd_register(
    const char *name, const char *type, uint16_t port, char *announced, size_t announced_capacity, char *error,
    size_t error_capacity);
/* Withdraws the announcement and frees it. */
void jsti_dnssd_unregister(jsti_dnssd *service);

#ifdef __cplusplus
}
#endif
#endif
