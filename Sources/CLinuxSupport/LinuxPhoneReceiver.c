#include "LinuxSupportInternal.h"

#include <adwaita.h>
#include <gio/gio.h>
#include <string.h>

/*
 * Send from phone (F46): the receiver's Settings group, and announcing the
 * receiver to phones through avahi-daemon. Swift runs the receiver itself
 * (DesktopHostPhoneReceiver); the group only reports the user's choices and
 * shows the state Swift hands it through jsti_window_set_phone_receiver,
 * applied in call order with the window's other setters.
 */

typedef struct PhoneDevice {
    gchar *id;
    gchar *name;
} PhoneDevice;

typedef struct PhoneView {
    gchar *status;
    gchar *code;
    gboolean available;
    gboolean enabled;
    GPtrArray *devices; /* PhoneDevice */
} PhoneView;

typedef struct PhoneGroup {
    AdwPreferencesGroup *group;
    AdwSwitchRow *enabled;
    AdwActionRow *status;
    AdwActionRow *code;
    GtkButton *new_code;
    /* "No paired phones", or one row per paired device with a Forget button. */
    AdwActionRow *empty;
    GPtrArray *device_rows;
    GPtrArray *forget_buttons;
    /* The last state shown; NULL status until one arrives. */
    PhoneView shown;
    /* Set while a state is shown, so the switch does not report it back. */
    gboolean showing;
} PhoneGroup;

static PhoneGroup phone;
static const char *const phone_initial_status = "Receiving from a phone has not started.";
/* The window's event callback; the self-test records events instead. */
static void (*phone_emit)(int32_t event, const char *text, int32_t index) = jsti_window_emit;

static void phone_device_free(gpointer pointer) {
    PhoneDevice *device = pointer;
    g_free(device->id);
    g_free(device->name);
    g_free(device);
}

static void phone_view_clear(PhoneView *view) {
    g_clear_pointer(&view->status, g_free);
    g_clear_pointer(&view->code, g_free);
    g_clear_pointer(&view->devices, g_ptr_array_unref);
    *view = (PhoneView){ 0 };
}

static void on_phone_forget(GtkButton *button, gpointer data) {
    (void)data;
    const char *id = g_object_get_data(G_OBJECT(button), "jsti-device-id");
    if (id != NULL) phone_emit(JSTI_EVENT_PHONE_RECEIVER_FORGET, id, 0);
}

static void rebuild_phone_devices(void) {
    for (guint index = 0; index < phone.device_rows->len; index++) {
        adw_preferences_group_remove(phone.group, g_ptr_array_index(phone.device_rows, index));
    }
    g_ptr_array_set_size(phone.device_rows, 0);
    g_ptr_array_set_size(phone.forget_buttons, 0);
    guint count = phone.shown.devices != NULL ? phone.shown.devices->len : 0;
    gtk_widget_set_visible(GTK_WIDGET(phone.empty), count == 0);
    for (guint index = 0; index < count; index++) {
        PhoneDevice *device = g_ptr_array_index(phone.shown.devices, index);
        AdwActionRow *row = ADW_ACTION_ROW(adw_action_row_new());
        adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(row), FALSE);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), device->name);
        adw_action_row_set_subtitle(row, "Paired. Sends without the code.");
        GtkWidget *forget = gtk_button_new_with_label("Forget");
        gtk_widget_set_valign(forget, GTK_ALIGN_CENTER);
        /* Repeated buttons carry their item in the name. */
        gchar *name = g_strdup_printf("Forget %s", device->name);
        jsti_accessible_set_name(forget, name);
        g_free(name);
        g_object_set_data_full(G_OBJECT(forget), "jsti-device-id", g_strdup(device->id), g_free);
        g_signal_connect(forget, "clicked", G_CALLBACK(on_phone_forget), NULL);
        adw_action_row_add_suffix(row, forget);
        adw_preferences_group_add(phone.group, GTK_WIDGET(row));
        g_ptr_array_add(phone.device_rows, row);
        g_ptr_array_add(phone.forget_buttons, forget);
    }
}

static gboolean same_devices(GPtrArray *left, GPtrArray *right) {
    guint left_count = left != NULL ? left->len : 0, right_count = right != NULL ? right->len : 0;
    if (left_count != right_count) return FALSE;
    for (guint index = 0; index < left_count; index++) {
        PhoneDevice *a = g_ptr_array_index(left, index), *b = g_ptr_array_index(right, index);
        if (g_strcmp0(a->id, b->id) != 0 || g_strcmp0(a->name, b->name) != 0) return FALSE;
    }
    return TRUE;
}

/* Shows a state, taking ownership of `view`'s contents. */
static void show_phone(PhoneView *view) {
    gboolean first = phone.shown.status == NULL;
    if (view->status == NULL) view->status = g_strdup(phone_initial_status);
    if (view->code == NULL) view->code = g_strdup("");
    gboolean announce = !first && (g_strcmp0(view->status, phone.shown.status) != 0);
    gboolean devices_changed = first || !same_devices(view->devices, phone.shown.devices);
    phone.showing = TRUE;
    adw_switch_row_set_active(phone.enabled, view->enabled);
    phone.showing = FALSE;
    adw_action_row_set_subtitle(phone.status, view->status);
    adw_action_row_set_subtitle(
        phone.code, view->enabled && view->code[0] != 0 ? view->code : "Turn receiving on to see the code.");
    phone_view_clear(&phone.shown);
    phone.shown = *view;
    *view = (PhoneView){ 0 };
    gtk_widget_set_sensitive(GTK_WIDGET(phone.enabled), phone.shown.available);
    gtk_widget_set_sensitive(GTK_WIDGET(phone.new_code), phone.shown.available && phone.shown.enabled);
    if (devices_changed) rebuild_phone_devices();
    if (announce) {
        jsti_accessible_announce(
            GTK_WIDGET(phone.status), phone.shown.status, GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
    }
}

/* Back to "not started": nothing can be used. */
static void reset_phone(void) {
    phone_view_clear(&phone.shown);
    PhoneView initial = { 0 };
    show_phone(&initial);
}

static void on_phone_enabled(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (phone.showing) return;
    phone_emit(JSTI_EVENT_PHONE_RECEIVER_ENABLE, "", adw_switch_row_get_active(phone.enabled) ? 1 : 0);
}

static void on_phone_new_code(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    phone_emit(JSTI_EVENT_PHONE_RECEIVER_NEW_CODE, "", 0);
}

struct _GtkWidget *jsti_phone_receiver_group_new(void) {
    GtkWidget *group = adw_preferences_group_new();
    phone.group = ADW_PREFERENCES_GROUP(group);
    adw_preferences_group_set_title(phone.group, "Send from phone");
    adw_preferences_group_set_description(
        phone.group,
        "Dictate on your iPhone or iPad and the final transcript is typed where your cursor is here. The phone "
        "must be on the same network. Transcripts are encrypted and not saved to this computer's History.");
    phone.enabled = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(phone.enabled), "Receive transcripts from a phone");
    g_signal_connect(phone.enabled, "notify::active", G_CALLBACK(on_phone_enabled), NULL);
    adw_preferences_group_add(phone.group, GTK_WIDGET(phone.enabled));

    phone.status = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(phone.status), "Status");
    adw_preferences_group_add(phone.group, GTK_WIDGET(phone.status));

    phone.code = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(phone.code), "Pairing code");
    phone.new_code = GTK_BUTTON(gtk_button_new_with_mnemonic("_New code"));
    gtk_widget_set_valign(GTK_WIDGET(phone.new_code), GTK_ALIGN_CENTER);
    jsti_accessible_set_name(GTK_WIDGET(phone.new_code), "New pairing code");
    g_signal_connect(phone.new_code, "clicked", G_CALLBACK(on_phone_new_code), NULL);
    adw_action_row_add_suffix(phone.code, GTK_WIDGET(phone.new_code));
    adw_preferences_group_add(phone.group, GTK_WIDGET(phone.code));

    phone.empty = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(phone.empty), "Paired phones");
    adw_action_row_set_subtitle(phone.empty, "None yet. Enter the pairing code on your phone to pair it.");
    adw_preferences_group_add(phone.group, GTK_WIDGET(phone.empty));
    phone.device_rows = g_ptr_array_new();
    phone.forget_buttons = g_ptr_array_new();
    reset_phone();
    return group;
}

static void phone_view_free(gpointer pointer) {
    PhoneView *view = pointer;
    phone_view_clear(view);
    g_free(view);
}

static void phone_view_apply(gpointer pointer) { show_phone(pointer); }

int32_t jsti_window_set_phone_receiver(const JSTIPhoneReceiverView *view) {
    if (view == NULL || view->device_count < 0 ||
        (view->device_count > 0 && (view->device_ids == NULL || view->device_names == NULL))) {
        return -1;
    }
    PhoneView *copy = g_new0(PhoneView, 1);
    copy->status = g_strdup(view->status);
    copy->code = g_strdup(view->pairing_code);
    copy->available = view->available != 0;
    copy->enabled = view->enabled != 0;
    copy->devices = g_ptr_array_new_with_free_func(phone_device_free);
    for (int32_t index = 0; index < view->device_count; index++) {
        PhoneDevice *device = g_new0(PhoneDevice, 1);
        device->id = g_strdup(view->device_ids[index] != NULL ? view->device_ids[index] : "");
        device->name = g_strdup(view->device_names[index] != NULL ? view->device_names[index] : "Phone");
        g_ptr_array_add(copy->devices, device);
    }
    return jsti_window_post(phone_view_apply, copy, phone_view_free);
}

/* ------------------------------------------------------------ DNS-SD (Avahi) */

struct jsti_dnssd {
    GDBusConnection *bus;
    gchar *group;
};

static const char *const avahi_name = "org.freedesktop.Avahi";
static const char *const avahi_group_interface = "org.freedesktop.Avahi.EntryGroup";

static GVariant *avahi_call(
    GDBusConnection *bus, const char *path, const char *interface, const char *method, GVariant *arguments,
    const GVariantType *reply, GError **failure) {
    return g_dbus_connection_call_sync(
        bus, avahi_name, path, interface, method, arguments, reply, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, failure);
}

static gboolean avahi_collision(GError *failure) {
    gchar *remote = failure != NULL ? g_dbus_error_get_remote_error(failure) : NULL;
    gboolean collision = g_strcmp0(remote, "org.freedesktop.Avahi.CollisionError") == 0;
    g_free(remote);
    return collision;
}

static void avahi_unreachable(char *error, size_t capacity, GError *failure) {
    /* The Flatpak reaches the host's daemon through --system-talk-name. */
    jsti_set_error(
        error, capacity,
        "Phones cannot find this computer because Avahi (avahi-daemon) is not running: %s",
        failure != NULL ? failure->message : "no reply.");
}

/* Avahi's EntryGroup states. */
enum { avahi_group_registering = 1, avahi_group_established = 2, avahi_group_collision = 3 };

/* Waits while Avahi probes the network for the committed name, polling
 * GetState, since a clash with another host is reported only after Commit.
 * Returns the state, or -1 when Avahi stops answering. A group still probing
 * after five seconds (for example with no network up) is left to finish. */
static gint32 avahi_wait_for_probe(GDBusConnection *bus, const char *group, GError **failure) {
    gint32 state = avahi_group_registering;
    for (int poll = 0; poll < 50 && state == avahi_group_registering; poll++) {
        if (poll > 0) g_usleep(100 * 1000);
        GVariant *reply =
            avahi_call(bus, group, avahi_group_interface, "GetState", NULL, G_VARIANT_TYPE("(i)"), failure);
        if (reply == NULL) return -1;
        g_variant_get(reply, "(i)", &state);
        g_variant_unref(reply);
    }
    return state;
}

static gboolean avahi_rename(GDBusConnection *bus, gchar **service_name, GError **failure) {
    GVariant *reply = avahi_call(
        bus, "/", "org.freedesktop.Avahi.Server", "GetAlternativeServiceName",
        g_variant_new("(s)", *service_name), G_VARIANT_TYPE("(s)"), failure);
    if (reply == NULL) return FALSE;
    g_free(*service_name);
    g_variant_get(reply, "(s)", service_name);
    g_variant_unref(reply);
    return TRUE;
}

jsti_dnssd *jsti_dnssd_register(
    const char *name, const char *type, uint16_t port, char *announced, size_t announced_capacity, char *error,
    size_t capacity) {
    if (announced != NULL && announced_capacity > 0) announced[0] = 0;
    if (name == NULL || name[0] == 0 || type == NULL || type[0] == 0 || port == 0) {
        jsti_set_error(error, capacity, "A service name, type and port are required.");
        return NULL;
    }
    GError *failure = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &failure);
    if (bus == NULL) {
        avahi_unreachable(error, capacity, failure);
        g_clear_error(&failure);
        return NULL;
    }
    GVariant *reply = avahi_call(
        bus, "/", "org.freedesktop.Avahi.Server", "EntryGroupNew", NULL, G_VARIANT_TYPE("(o)"), &failure);
    if (reply == NULL) {
        avahi_unreachable(error, capacity, failure);
        g_clear_error(&failure);
        g_object_unref(bus);
        return NULL;
    }
    jsti_dnssd *service = g_new0(jsti_dnssd, 1);
    service->bus = bus;
    g_variant_get(reply, "(o)", &service->group);
    g_variant_unref(reply);

    /* The group lives as long as this bus connection. A name already taken,
     * here (AddService fails) or by another host (the probe after Commit
     * collides), is retried with Avahi's alternative ("Name #2"). */
    gchar *service_name = g_strdup(name);
    gboolean published = FALSE;
    const char *reason = "the name is taken.";
    for (int attempt = 0; attempt < 8 && !published; attempt++) {
        if (attempt > 0) {
            if (!avahi_rename(bus, &service_name, &failure)) break;
            reply = avahi_call(bus, service->group, avahi_group_interface, "Reset", NULL, NULL, &failure);
            if (reply == NULL) break;
            g_variant_unref(reply);
        }
        GVariant *txt = g_variant_new_array(G_VARIANT_TYPE("ay"), NULL, 0);
        reply = avahi_call(
            bus, service->group, avahi_group_interface, "AddService",
            g_variant_new("(iiussssq@aay)", -1, -1, 0u, service_name, type, "", "", (guint16)port, txt),
            NULL, &failure);
        if (reply == NULL) {
            if (!avahi_collision(failure)) break;
            g_clear_error(&failure);
            continue;
        }
        g_variant_unref(reply);
        reply = avahi_call(bus, service->group, avahi_group_interface, "Commit", NULL, NULL, &failure);
        if (reply == NULL) break;
        g_variant_unref(reply);
        gint32 state = avahi_wait_for_probe(bus, service->group, &failure);
        if (state == avahi_group_established || state == avahi_group_registering) {
            published = TRUE;
        } else if (state != avahi_group_collision) {
            if (state >= 0) reason = "Avahi could not publish the service.";
            break;
        }
    }
    if (published) {
        if (announced != NULL && announced_capacity > 0) g_strlcpy(announced, service_name, announced_capacity);
        g_free(service_name);
        return service;
    }
    g_free(service_name);
    jsti_set_error(
        error, capacity, "Avahi could not announce this computer to phones: %s",
        failure != NULL ? failure->message : reason);
    g_clear_error(&failure);
    jsti_dnssd_unregister(service);
    return NULL;
}

void jsti_dnssd_unregister(jsti_dnssd *service) {
    if (service == NULL) return;
    if (service->group != NULL) {
        GVariant *reply = avahi_call(service->bus, service->group, avahi_group_interface, "Free", NULL, NULL, NULL);
        if (reply != NULL) g_variant_unref(reply);
    }
    g_free(service->group);
    g_object_unref(service->bus);
    g_free(service);
}

/* --------------------------------------------------------------- self-test */

typedef struct PhoneEmitted {
    gint calls;
    gint32 event;
    gint32 index;
    gchar *text;
} PhoneEmitted;

static PhoneEmitted phone_emitted;

static void phone_record_emit(int32_t event, const char *text, int32_t index) {
    phone_emitted.calls++;
    phone_emitted.event = event;
    phone_emitted.index = index;
    g_free(phone_emitted.text);
    phone_emitted.text = g_strdup(text);
}

static PhoneView phone_test_view(const char *status, gboolean enabled, guint devices) {
    PhoneView view = { .status = g_strdup(status), .code = g_strdup(enabled ? "123456" : ""), .available = TRUE,
                       .enabled = enabled, .devices = g_ptr_array_new_with_free_func(phone_device_free) };
    for (guint index = 0; index < devices; index++) {
        PhoneDevice *device = g_new0(PhoneDevice, 1);
        device->id = g_strdup_printf("device-%u", index);
        device->name = g_strdup_printf("Phone %u", index);
        g_ptr_array_add(view.devices, device);
    }
    return view;
}

static const char *check_phone_group(void) {
    if (jsti_window_set_phone_receiver(NULL) != -1) return "a missing phone receiver state was accepted";
    JSTIPhoneReceiverView broken = { .device_count = 1 };
    if (jsti_window_set_phone_receiver(&broken) != -1) return "phone receiver devices without names were accepted";
    if (gtk_widget_get_sensitive(GTK_WIDGET(phone.enabled)) || gtk_widget_get_sensitive(GTK_WIDGET(phone.new_code))) {
        return "the phone receiver could be used before it started";
    }
    PhoneView off = phone_test_view("Off.", FALSE, 0);
    show_phone(&off);
    if (phone_emitted.calls != 0) return "showing the receiver's state reported it back as a choice";
    if (!gtk_widget_get_sensitive(GTK_WIDGET(phone.enabled)) || gtk_widget_get_sensitive(GTK_WIDGET(phone.new_code))) {
        return "a new pairing code could be made while the receiver was off";
    }
    adw_switch_row_set_active(phone.enabled, TRUE);
    if (phone_emitted.calls != 1 || phone_emitted.event != JSTI_EVENT_PHONE_RECEIVER_ENABLE ||
        phone_emitted.index != 1) {
        return "turning the receiver on was not reported once";
    }
    PhoneView on = phone_test_view("On.", TRUE, 2);
    show_phone(&on);
    if (g_strcmp0(adw_action_row_get_subtitle(phone.code), "123456") != 0) return "the pairing code was not shown";
    if (phone.device_rows->len != 2 || gtk_widget_get_visible(GTK_WIDGET(phone.empty))) {
        return "paired phones were not listed";
    }
    g_signal_emit_by_name(phone.new_code, "clicked");
    if (phone_emitted.calls != 2 || phone_emitted.event != JSTI_EVENT_PHONE_RECEIVER_NEW_CODE) {
        return "New code was not reported";
    }
    GtkWidget *button = phone.forget_buttons->len == 2 ? g_ptr_array_index(phone.forget_buttons, 1) : NULL;
    if (button == NULL) return "a paired phone had no Forget button";
    g_signal_emit_by_name(button, "clicked");
    if (phone_emitted.calls != 3 || phone_emitted.event != JSTI_EVENT_PHONE_RECEIVER_FORGET ||
        g_strcmp0(phone_emitted.text, "device-1") != 0) {
        return "Forget did not report the paired phone";
    }
    PhoneView forgot = phone_test_view("On.", TRUE, 0);
    show_phone(&forgot);
    if (phone.device_rows->len != 0 || !gtk_widget_get_visible(GTK_WIDGET(phone.empty))) {
        return "a forgotten phone stayed listed";
    }
    char failure[256];
    if (jsti_dnssd_register("", "_speaktransport._tcp", 1, NULL, 0, failure, sizeof failure) != NULL ||
        jsti_dnssd_register("Desktop", "_speaktransport._tcp", 0, NULL, 0, failure, sizeof failure) != NULL) {
        return "an announcement without a name or port was accepted";
    }
    return NULL;
}

int32_t jsti_phone_receiver_self_test(char *error, size_t capacity) {
    if (phone.group == NULL) {
        jsti_set_error(error, capacity, "Window self-test: the Send from phone group was not built");
        return -1;
    }
    /* The group is exercised with recorded events, then put back as it was. */
    PhoneView before = phone.shown;
    phone.shown = (PhoneView){ 0 };
    reset_phone();
    phone_emit = phone_record_emit;
    const char *failure = check_phone_group();
    phone_emit = jsti_window_emit;
    g_clear_pointer(&phone_emitted.text, g_free);
    phone_emitted = (PhoneEmitted){ 0 };
    if (before.status != NULL) {
        show_phone(&before);
    } else {
        reset_phone();
    }
    if (failure != NULL) {
        jsti_set_error(error, capacity, "Window self-test: %s", failure);
        return -1;
    }
    return 0;
}
