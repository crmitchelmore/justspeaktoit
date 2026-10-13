#include "LinuxSupportInternal.h"

#include <adwaita.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifdef GDK_WINDOWING_X11
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <gdk/x11/gdkx.h>
#endif

/*
 * The recording HUD: the Mac's bottom-centre dictation card. Phases and
 * wording come from the shared DesktopHUDState; this draws them with GTK.
 *
 * On X11 it is an undecorated notification window above other windows at the
 * bottom centre of the active window's monitor, click-through and never
 * focused, so insertion still reaches the field the user was typing in.
 * Wayland lets no client place or raise its own window, and a new window may
 * take focus from that field, so there the HUD shows nothing while working
 * and a desktop notification reports the result when the window is not
 * active; the window's status line and dashboard follow every phase.
 */

enum { HUD_HIDDEN, HUD_RECORDING, HUD_TRANSCRIBING, HUD_POST_PROCESSING, HUD_DELIVERING, HUD_SUCCESS, HUD_FAILURE,
       HUD_PHASES };

/* Prefixed: libadwaita already styles .success and .error text. */
static const char *phase_class[HUD_PHASES] = {
    "", "hud-recording", "hud-transcribing", "hud-post-processing", "hud-delivering", "hud-success", "hud-failure" };
static const char *phase_icon[HUD_PHASES] = {
    "", "audio-input-microphone-symbolic", "emblem-synchronizing-symbolic", "starred-symbolic",
    "mail-send-symbolic", "object-select-symbolic", "dialog-warning-symbolic" };

static const char *hud_css =
    "window.jsti-hud-window { background: transparent; box-shadow: none; }\n"
    ".jsti-hud { margin: 14px 18px 22px 18px; padding: 16px 24px; border-radius: 20px;"
    " background-color: alpha(@window_bg_color, 0.97); border: 1.5px solid alpha(#D92A2A, 0.45);"
    " box-shadow: 0 12px 18px -6px alpha(#000000, 0.25); }\n"
    ".jsti-hud.hud-transcribing { border-color: alpha(#1AAB99, 0.45); }\n"
    ".jsti-hud.hud-post-processing { border-color: alpha(#FF6B3D, 0.45);"
    " background-image: linear-gradient(alpha(#FF6B3D, 0.06), alpha(#FF6B3D, 0.06)); }\n"
    ".jsti-hud.hud-delivering, .jsti-hud.hud-success { border-color: alpha(#26A269, 0.45); }\n"
    ".jsti-hud.hud-failure { background-image: linear-gradient(alpha(#D92A2A, 0.18), alpha(#D92A2A, 0.18)); }\n"
    ".jsti-hud-glyph { min-width: 40px; min-height: 40px; border-radius: 20px; color: #ffffff;"
    " background-image: linear-gradient(180deg, #FF7B7B, #D92A2A); }\n"
    ".hud-transcribing .jsti-hud-glyph { background-image: linear-gradient(180deg, #5FE0D1, #1AAB99); }\n"
    ".hud-post-processing .jsti-hud-glyph { background-image: linear-gradient(180deg, #FF9C4A, #FF6B3D); }\n"
    ".hud-delivering .jsti-hud-glyph, .hud-success .jsti-hud-glyph {"
    " background-image: linear-gradient(180deg, #57C98E, #26A269); }\n"
    ".hud-recording .jsti-hud-glyph.pulse { box-shadow: 0 0 0 5px alpha(#D92A2A, 0.28); }\n"
    ".jsti-hud-title { font-weight: 700; font-size: 15px; }\n"
    ".hud-failure .jsti-hud-title { color: #D92A2A; }\n"
    ".jsti-hud-detail { font-size: 12.5px; opacity: 0.7; }\n"
    ".jsti-hud-clock { font-size: 12px; opacity: 0.7; font-feature-settings: 'tnum'; }\n"
    ".jsti-hud levelbar block.filled { background-color: #D92A2A; border-radius: 2px; }\n"
    ".jsti-hud levelbar block.empty { background-color: alpha(currentColor, 0.15); border-radius: 2px; }\n"
    ".jsti-hud levelbar trough { min-height: 4px; padding: 0; border: none; background: none; }\n"
    ".jsti-hud-live { background-color: alpha(currentColor, 0.06); border-radius: 10px; padding: 10px;"
    " font-size: 13px; }\n"
    ".jsti-hud.compact { padding: 12px 18px; }\n"
    ".jsti-hud.compact .jsti-hud-glyph { min-width: 15px; min-height: 15px; border-radius: 8px; }\n"
    ".jsti-hud.compact .jsti-hud-clock { font-size: 16px; }\n"
    ".jsti-hud.compact .jsti-hud-live { background: none; border-radius: 0; padding: 0; }\n";

static struct {
    GtkWindow *window;
    GtkWidget *root, *card, *glyph, *title, *detail, *meter, *clock, *live;
    int phase, styled; /* the phase shown, and the one the card's class names */
    gint64 phase_started;
    double level;
    guint tick, hide;
    guint64 generation;
    gboolean compact;
    GtkCssProvider *css;
    gchar *headline, *subheadline, *live_text;
} hud;

static gboolean hud_is_x11(void) {
#ifdef GDK_WINDOWING_X11
    return GDK_IS_X11_DISPLAY(gdk_display_get_default());
#else
    return FALSE;
#endif
}

gboolean jsti_hud_overlay_supported(void) { return hud_is_x11(); }

static gchar *clock_text(gint64 microseconds) {
    if (hud.compact) {
        const gint64 seconds = MAX(microseconds, 0) / G_USEC_PER_SEC;
        return seconds >= 60 ? g_strdup_printf("%" G_GINT64_FORMAT ":%02" G_GINT64_FORMAT "s", seconds / 60, seconds % 60)
                             : g_strdup_printf("%" G_GINT64_FORMAT "s", seconds);
    }
    const gint64 hundredths_total = (MAX(microseconds, 0) + 5000) / 10000;
    const int minutes = (int)(hundredths_total / 6000), seconds = (int)((hundredths_total / 100) % 60);
    const int hundredths = (int)(hundredths_total % 100);
    return minutes > 0 ? g_strdup_printf("%02d:%02d.%02d", minutes, seconds, hundredths)
                       : g_strdup_printf("%02d.%02ds", seconds, hundredths);
}

/* Two lines of the latest words: earlier words drop off the front. */
static gchar *live_tail(const char *text) {
    const glong limit = 120;
    const glong length = g_utf8_strlen(text, -1);
    if (length <= limit) return g_strdup(text);
    const char *start = g_utf8_offset_to_pointer(text, length - limit);
    const char *space = strchr(start, ' ');
    return g_strconcat("…", space != NULL && space[1] != '\0' ? space + 1 : start, NULL);
}

static void hud_tick_apply(void) {
    if (hud.window == NULL) return;
    gchar *clock = clock_text(g_get_monotonic_time() - hud.phase_started);
    gtk_label_set_text(GTK_LABEL(hud.clock), clock);
    g_free(clock);
    if (hud.phase == HUD_RECORDING) {
        /* Rises with each frame and falls back smoothly between them. */
        hud.level = MAX(jsti_capture_level(), hud.level * 0.82);
        gtk_level_bar_set_value(GTK_LEVEL_BAR(hud.meter), hud.level);
        const double pulse = 0.5 + 0.5 * sin((double)(g_get_monotonic_time() - hud.phase_started) / 1e6 * G_PI * 1.6);
        if (pulse > 0.5) gtk_widget_add_css_class(hud.glyph, "pulse");
        else gtk_widget_remove_css_class(hud.glyph, "pulse");
    }
}

static gboolean hud_tick(gpointer data) {
    (void)data;
    hud_tick_apply();
    return G_SOURCE_CONTINUE;
}

static void hud_stop_timers(void) {
    ++hud.generation;
    if (hud.tick != 0) g_source_remove(hud.tick);
    if (hud.hide != 0) g_source_remove(hud.hide);
    hud.tick = hud.hide = 0;
}

static void hud_hide(void) {
    hud_stop_timers();
    hud.phase = HUD_HIDDEN;
    hud.level = 0;
    if (hud.window != NULL) gtk_widget_set_visible(GTK_WIDGET(hud.window), FALSE);
}

static gboolean hud_hide_later(gpointer data) {
    const guint64 generation = *(const guint64 *)data;
    if (generation != hud.generation || (hud.phase != HUD_SUCCESS && hud.phase != HUD_FAILURE))
        return G_SOURCE_REMOVE;
    hud.hide = 0;
    hud_hide();
    return G_SOURCE_REMOVE;
}

#ifdef GDK_WINDOWING_X11
/* The monitor holding the active window, or the first one. */
static GdkMonitor *active_monitor(GdkDisplay *display) {
    Display *x = gdk_x11_display_get_xdisplay(display);
    Window root = DefaultRootWindow(x), active = None;
    Atom property = XInternAtom(x, "_NET_ACTIVE_WINDOW", False), type;
    int format;
    unsigned long count, remaining;
    unsigned char *value = NULL;
    if (XGetWindowProperty(x, root, property, 0, 1, False, XA_WINDOW, &type, &format, &count, &remaining, &value) ==
            Success && value != NULL && count == 1) {
        active = *(Window *)value;
    }
    if (value != NULL) XFree(value);
    GListModel *monitors = gdk_display_get_monitors(display);
    GdkMonitor *chosen = g_list_model_get_n_items(monitors) > 0 ? g_list_model_get_item(monitors, 0) : NULL;
    XWindowAttributes attributes;
    Window child;
    int x0, y0;
    if (active != None && XGetWindowAttributes(x, active, &attributes) &&
        XTranslateCoordinates(x, active, root, attributes.width / 2, attributes.height / 2, &x0, &y0, &child)) {
        for (guint index = 0; index < g_list_model_get_n_items(monitors); ++index) {
            GdkMonitor *monitor = g_list_model_get_item(monitors, index);
            GdkRectangle area;
            gdk_monitor_get_geometry(monitor, &area);
            const int scale = gdk_monitor_get_scale_factor(monitor);
            if (x0 >= area.x * scale && x0 < (area.x + area.width) * scale && y0 >= area.y * scale &&
                y0 < (area.y + area.height) * scale) {
                g_clear_object(&chosen);
                chosen = monitor;
                break;
            }
            g_object_unref(monitor);
        }
    }
    return chosen;
}

static void set_atom(Display *x, Window window, const char *name, const char *value) {
    Atom atom = XInternAtom(x, value, False);
    XChangeProperty(x, window, XInternAtom(x, name, False), XA_ATOM, 32, PropModeReplace, (unsigned char *)&atom, 1);
}

/* Before mapping: a notification that asks for no input and no focus. */
static void hud_realized(GtkWidget *widget, gpointer data) {
    (void)data;
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(widget));
    if (!GDK_IS_X11_SURFACE(surface)) return;
    Display *x = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
    const Window xid = gdk_x11_surface_get_xid(surface);
    set_atom(x, xid, "_NET_WM_WINDOW_TYPE", "_NET_WM_WINDOW_TYPE_NOTIFICATION");
    gdk_x11_surface_set_skip_taskbar_hint(surface, TRUE);
    gdk_x11_surface_set_skip_pager_hint(surface, TRUE);
    gdk_x11_surface_set_user_time(surface, 0);
    cairo_region_t *none = cairo_region_create();
    gdk_surface_set_input_region(surface, none);
    cairo_region_destroy(none);
}

/* After mapping: keep it above, refuse input focus and place it. */
static void hud_place(void) {
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(hud.window));
    if (surface == NULL || !GDK_IS_X11_SURFACE(surface)) return;
    GdkDisplay *display = gdk_surface_get_display(surface);
    Display *x = gdk_x11_display_get_xdisplay(display);
    const Window xid = gdk_x11_surface_get_xid(surface);
    XWMHints *hints = XGetWMHints(x, xid);
    if (hints == NULL) hints = XAllocWMHints();
    if (hints != NULL) {
        hints->flags |= InputHint;
        hints->input = False;
        XSetWMHints(x, xid, hints);
        XFree(hints);
    }
    XEvent above = { 0 };
    above.xclient.type = ClientMessage;
    above.xclient.window = xid;
    above.xclient.message_type = XInternAtom(x, "_NET_WM_STATE", False);
    above.xclient.format = 32;
    above.xclient.data.l[0] = 1; /* _NET_WM_STATE_ADD */
    above.xclient.data.l[1] = (long)XInternAtom(x, "_NET_WM_STATE_ABOVE", False);
    above.xclient.data.l[2] = (long)XInternAtom(x, "_NET_WM_STATE_STICKY", False);
    above.xclient.data.l[3] = 1;
    XSendEvent(x, DefaultRootWindow(x), False, SubstructureRedirectMask | SubstructureNotifyMask, &above);
    GdkMonitor *monitor = active_monitor(display);
    if (monitor != NULL) {
        GdkRectangle work;
        gdk_x11_monitor_get_workarea(monitor, &work);
        const int scale = gdk_monitor_get_scale_factor(monitor);
        int width = 0, height = 0;
        gtk_widget_measure(GTK_WIDGET(hud.window), GTK_ORIENTATION_HORIZONTAL, -1, NULL, &width, NULL, NULL);
        gtk_widget_measure(GTK_WIDGET(hud.window), GTK_ORIENTATION_VERTICAL, width, NULL, &height, NULL, NULL);
        /* The card's bottom edge sits 24 px above the work area; its margin is 22. */
        const int left = work.x + (work.width - width) / 2, top = work.y + work.height - height - 2;
        XMoveWindow(x, xid, left * scale, top * scale);
        g_object_unref(monitor);
    }
    XFlush(x);
}
#endif

static GtkWidget *hud_label(const char *css) {
    GtkWidget *label = gtk_label_new(NULL);
    gtk_widget_add_css_class(label, css);
    gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_xalign(GTK_LABEL(label), 0.5f);
    /* Wrap within the card rather than widen it. */
    gtk_label_set_max_width_chars(GTK_LABEL(label), 34);
    return label;
}

static void hud_build(void) {
    if (hud.css == NULL) {
        hud.css = gtk_css_provider_new();
        gtk_css_provider_load_from_string(hud.css, hud_css);
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(hud.css),
                                                   GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    }
    hud.window = GTK_WINDOW(gtk_window_new());
    gtk_window_set_title(hud.window, "Just Speak to It");
    gtk_window_set_decorated(hud.window, FALSE);
    gtk_window_set_resizable(hud.window, FALSE);
    gtk_window_set_focus_visible(hud.window, FALSE);
    gtk_widget_set_can_focus(GTK_WIDGET(hud.window), FALSE);
    gtk_widget_set_can_target(GTK_WIDGET(hud.window), FALSE);
    gtk_widget_add_css_class(GTK_WIDGET(hud.window), "jsti-hud-window");
#ifdef GDK_WINDOWING_X11
    g_signal_connect(hud.window, "realize", G_CALLBACK(hud_realized), NULL);
#endif
    hud.card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(hud.card, "jsti-hud");
    if (hud.compact) gtk_widget_add_css_class(hud.card, "compact");
    hud.glyph = gtk_image_new();
    gtk_image_set_pixel_size(GTK_IMAGE(hud.glyph), 18);
    gtk_widget_add_css_class(hud.glyph, "jsti-hud-glyph");
    gtk_widget_set_halign(hud.glyph, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_bottom(hud.glyph, hud.compact ? 0 : 12);
    hud.title = hud_label("jsti-hud-title");
    hud.detail = hud_label("jsti-hud-detail");
    gtk_label_set_lines(GTK_LABEL(hud.detail), hud.compact ? 1 : 3);
    if (hud.compact) {
        gtk_label_set_wrap(GTK_LABEL(hud.detail), FALSE);
        gtk_label_set_max_width_chars(GTK_LABEL(hud.detail), 23);
    }
    gtk_label_set_ellipsize(GTK_LABEL(hud.detail), PANGO_ELLIPSIZE_END);
    gtk_widget_set_margin_top(hud.detail, hud.compact ? 7 : 4);
    hud.meter = gtk_level_bar_new_for_interval(0, 1);
    gtk_level_bar_remove_offset_value(GTK_LEVEL_BAR(hud.meter), GTK_LEVEL_BAR_OFFSET_LOW);
    gtk_level_bar_remove_offset_value(GTK_LEVEL_BAR(hud.meter), GTK_LEVEL_BAR_OFFSET_HIGH);
    gtk_level_bar_remove_offset_value(GTK_LEVEL_BAR(hud.meter), GTK_LEVEL_BAR_OFFSET_FULL);
    gtk_widget_set_size_request(hud.meter, hud.compact ? 80 : 100, 4);
    gtk_widget_set_halign(hud.meter, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(hud.meter, hud.compact ? 0 : 10);
    hud.clock = hud_label("jsti-hud-clock");
    gtk_widget_set_margin_top(hud.clock, hud.compact ? 0 : 8);
    hud.live = gtk_label_new(NULL);
    gtk_widget_add_css_class(hud.live, "jsti-hud-live");
    gtk_label_set_wrap(GTK_LABEL(hud.live), !hud.compact);
    gtk_label_set_lines(GTK_LABEL(hud.live), hud.compact ? 1 : 2);
    gtk_label_set_ellipsize(GTK_LABEL(hud.live), hud.compact ? PANGO_ELLIPSIZE_START : PANGO_ELLIPSIZE_END);
    gtk_label_set_xalign(GTK_LABEL(hud.live), hud.compact ? 1 : 0);
    gtk_label_set_max_width_chars(GTK_LABEL(hud.live), hud.compact ? 23 : 46);
    gtk_widget_set_margin_top(hud.live, hud.compact ? 7 : 12);
    GtkWidget *parts[] = { hud.glyph, hud.title, hud.detail, hud.meter, hud.clock, hud.live };
    if (hud.compact) {
        GtkWidget *row = gtk_overlay_new();
        GtkWidget *edges = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *space = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_widget_set_hexpand(space, TRUE);
        gtk_widget_set_size_request(row, -1, 24);
        GtkWidget *indicators[] = { hud.glyph, hud.meter, hud.clock };
        for (size_t index = 0; index < G_N_ELEMENTS(indicators); ++index)
            gtk_widget_set_valign(indicators[index], GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(edges), hud.glyph);
        gtk_box_append(GTK_BOX(edges), space);
        gtk_box_append(GTK_BOX(edges), hud.clock);
        gtk_overlay_set_child(GTK_OVERLAY(row), edges);
        gtk_overlay_add_overlay(GTK_OVERLAY(row), hud.meter);
        gtk_box_append(GTK_BOX(hud.card), row);
        gtk_box_append(GTK_BOX(hud.card), hud.title);
        gtk_box_append(GTK_BOX(hud.card), hud.detail);
        gtk_box_append(GTK_BOX(hud.card), hud.live);
    } else {
        for (size_t index = 0; index < G_N_ELEMENTS(parts); ++index) gtk_box_append(GTK_BOX(hud.card), parts[index]);
    }
    /* The card's CSS margin leaves room for its shadow inside the window. */
    hud.root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(hud.root), hud.card);
    gtk_window_set_child(hud.window, hud.root);
}

static void hud_notify(int phase, const char *headline, const char *subheadline) {
    if (phase != HUD_SUCCESS && phase != HUD_FAILURE) return;
    if (jsti_window_is_active()) return;
    GNotification *notification = g_notification_new(headline);
    if (subheadline != NULL && subheadline[0] != '\0') g_notification_set_body(notification, subheadline);
    if (phase == HUD_FAILURE) g_notification_set_priority(notification, G_NOTIFICATION_PRIORITY_HIGH);
    GApplication *application = g_application_get_default();
    if (application != NULL) g_application_send_notification(application, "dictation", notification);
    g_object_unref(notification);
}

void jsti_hud_show(int phase, const char *headline, const char *subheadline, const char *live) {
    jsti_hud_show_duration(phase, headline, subheadline, live, 0);
}

void jsti_hud_show_duration(int phase, const char *headline, const char *subheadline, const char *live,
                            int display_milliseconds) {
    jsti_hud_show_presentation(phase, headline, subheadline, live, display_milliseconds, FALSE);
}

void jsti_hud_show_presentation(int phase, const char *headline, const char *subheadline, const char *live,
                                int display_milliseconds, gboolean compact) {
    if (phase < HUD_HIDDEN || phase >= HUD_PHASES) return;
    if (phase == HUD_HIDDEN) { hud_hide(); return; }
    if (!hud_is_x11()) { hud_notify(phase, headline, subheadline); return; }
    if (hud.window != NULL && hud.compact != compact) {
        hud_stop_timers();
        gtk_window_destroy(hud.window);
        hud.window = NULL;
        hud.styled = HUD_HIDDEN;
    }
    hud.compact = compact;
    if (hud.window == NULL) hud_build();
    const gboolean new_phase = phase != hud.phase;
    if (new_phase || hud.styled != phase) {
        if (hud.styled != HUD_HIDDEN) gtk_widget_remove_css_class(hud.card, phase_class[hud.styled]);
        gtk_widget_add_css_class(hud.card, phase_class[phase]);
        hud.styled = phase;
        if (new_phase) hud.phase_started = g_get_monotonic_time();
        hud.phase = phase;
    }
    if (compact) gtk_image_clear(GTK_IMAGE(hud.glyph));
    else gtk_image_set_from_icon_name(GTK_IMAGE(hud.glyph), phase_icon[phase]);
    gtk_accessible_update_property(GTK_ACCESSIBLE(hud.glyph), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                    headline != NULL ? headline : "", -1);
    gtk_label_set_text(GTK_LABEL(hud.title), headline != NULL ? headline : "");
    gtk_widget_set_visible(hud.title, !compact);
    const gboolean recording = phase == HUD_RECORDING, finished = phase == HUD_SUCCESS || phase == HUD_FAILURE;
    const char *status = compact && (!finished || subheadline == NULL || subheadline[0] == '\0') ? headline : subheadline;
    gtk_label_set_text(GTK_LABEL(hud.detail), status != NULL ? status : "");
    gtk_widget_set_visible(hud.detail, (!compact || !recording) && status != NULL && status[0] != '\0');
    gtk_widget_set_visible(hud.meter, recording);
    gtk_widget_set_visible(hud.clock, !finished);
    gchar *tail = live_tail(live != NULL ? live : "");
    gtk_label_set_text(GTK_LABEL(hud.live), tail);
    gtk_widget_set_visible(hud.live, recording && tail[0] != '\0');
    /* As on the Mac: 320 px wide, 460 with live text, plus the 36 px margin. */
    gtk_widget_set_size_request(hud.root, (compact ? 244 : recording && tail[0] != '\0' ? 460 : 320) + 36, -1);
    g_free(tail);
    /* Screen readers announce each new phase. */
    if (new_phase) {
        gchar *announcement = subheadline != NULL && subheadline[0] != '\0'
            ? g_strdup_printf("%s. %s", headline, subheadline) : g_strdup(headline);
        gtk_accessible_announce(GTK_ACCESSIBLE(hud.card), announcement, finished && phase == HUD_FAILURE
                                ? GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_HIGH : GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
        g_free(announcement);
    }
    hud_stop_timers();
    if (finished) {
        const guint duration = display_milliseconds > 0 ? (guint)display_milliseconds :
            (phase == HUD_SUCCESS ? 2400 : 6000);
        guint64 *generation = g_new(guint64, 1);
        *generation = hud.generation;
        hud.hide = g_timeout_add_full(G_PRIORITY_DEFAULT, duration, hud_hide_later, generation, g_free);
    }
    else hud.tick = g_timeout_add(33, hud_tick, NULL);
    hud_tick_apply();
    gtk_widget_set_visible(GTK_WIDGET(hud.window), TRUE);
#ifdef GDK_WINDOWING_X11
    hud_place();
#endif
}

void jsti_hud_destroy(void) {
    hud_stop_timers();
    if (hud.window != NULL) gtk_window_destroy(hud.window);
    hud.window = NULL;
    hud.phase = hud.styled = HUD_HIDDEN;
}

GtkWidget *jsti_hud_card(void) {
    return hud.window != NULL && gtk_widget_get_visible(GTK_WIDGET(hud.window)) ? hud.root : NULL;
}

static void hud_wait(void) {
    for (int turn = 0; turn < 50; ++turn) {
        while (g_main_context_pending(NULL)) g_main_context_iteration(NULL, FALSE);
        g_usleep(2000);
    }
}

int32_t jsti_hud_self_test(char *error, size_t capacity) {
    if (!hud_is_x11()) {
        jsti_hud_show(HUD_RECORDING, "Recording", "Capturing audio", "");
        const gboolean shown = jsti_hud_card() != NULL;
        jsti_hud_show(HUD_HIDDEN, "", "", "");
        if (shown) { jsti_set_error(error, capacity, "Recording HUD: a window was shown on Wayland."); return -1; }
        return 0;
    }
    jsti_hud_show(HUD_RECORDING, "Recording", "Capturing audio", "Could we move the catch-up to Friday?");
    hud_wait();
    int32_t result = 0;
    const char *problem = NULL;
#ifdef GDK_WINDOWING_X11
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(hud.window));
    if (surface == NULL || !gtk_widget_get_mapped(GTK_WIDGET(hud.window))) {
        problem = "the recording phase did not show the HUD.";
    } else if (gtk_window_is_active(hud.window)) {
        problem = "the HUD took focus.";
    } else {
        Display *x = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
        const Window xid = gdk_x11_surface_get_xid(surface);
        XWMHints *hints = XGetWMHints(x, xid);
        const gboolean refuses = hints != NULL && (hints->flags & InputHint) && !hints->input;
        if (hints != NULL) XFree(hints);
        Atom type = None, actual;
        int format;
        unsigned long count, remaining;
        unsigned char *value = NULL;
        if (XGetWindowProperty(x, xid, XInternAtom(x, "_NET_WM_WINDOW_TYPE", False), 0, 1, False, XA_ATOM, &actual,
                               &format, &count, &remaining, &value) == Success && value != NULL && count == 1) {
            type = *(Atom *)value;
        }
        if (value != NULL) XFree(value);
        XWindowAttributes attributes;
        Window child;
        int left = 0, top = 0;
        XGetWindowAttributes(x, xid, &attributes);
        XTranslateCoordinates(x, xid, DefaultRootWindow(x), 0, 0, &left, &top, &child);
        GdkMonitor *monitor = active_monitor(gdk_surface_get_display(surface));
        GdkRectangle work = { 0 };
        if (monitor != NULL) { gdk_x11_monitor_get_workarea(monitor, &work); g_object_unref(monitor); }
        const int centre = left + attributes.width / 2, work_centre = work.x + work.width / 2;
        if (!refuses) problem = "the HUD accepts keyboard focus.";
        else if (type != XInternAtom(x, "_NET_WM_WINDOW_TYPE_NOTIFICATION", False)) problem = "the HUD is not a notification.";
        else if (abs(centre - work_centre) > 2 || top + attributes.height > work.y + work.height ||
                 work.y + work.height - (top + attributes.height) > 8) {
            problem = "the HUD is not at the bottom centre of the work area.";
        }
    }
#endif
    jsti_hud_show(HUD_SUCCESS, "Completed", "Transcript copied to the clipboard and saved to History.", "");
    hud_wait();
    if (problem == NULL && jsti_hud_card() == NULL) problem = "the completed phase did not stay up.";
    jsti_hud_show(HUD_RECORDING, "Recording", "Capturing audio", "Synthetic speech");
    hud_wait();
    const int full_width = gtk_widget_get_width(hud.root);
    const gint64 started = hud.phase_started;
    jsti_hud_show_presentation(HUD_RECORDING, "Recording", "Capturing audio",
                                "Could we move the catch-up to Friday? That gives us a little more time", 0, TRUE);
    hud_wait();
    if (problem == NULL && (gtk_widget_get_width(hud.root) >= full_width || gtk_widget_get_visible(hud.title) ||
                            gtk_widget_get_visible(hud.detail) || !gtk_widget_get_visible(hud.meter) ||
                            !gtk_widget_get_visible(hud.clock) || !gtk_widget_get_visible(hud.live) ||
                            gtk_label_get_wrap(GTK_LABEL(hud.live)) || gtk_label_get_lines(GTK_LABEL(hud.live)) != 1 ||
                            gtk_label_get_ellipsize(GTK_LABEL(hud.live)) != PANGO_ELLIPSIZE_START ||
                            hud.phase_started != started || gtk_window_is_active(hud.window)))
        problem = "the compact layout lost its meter, clock, trailing transcript or focus safety.";
    gchar *compact_clock = clock_text(83999000);
    if (problem == NULL && g_strcmp0(compact_clock, "1:23s") != 0)
        problem = "the compact clock did not use whole seconds.";
    g_free(compact_clock);
    jsti_hud_show_presentation(HUD_RECORDING, "Recording", "Capturing audio", "", 0, TRUE);
    if (problem == NULL && (gtk_widget_get_visible(hud.live) || gtk_widget_get_visible(hud.detail)))
        problem = "a disabled compact transcript showed placeholder status text.";
    jsti_hud_show_presentation(HUD_FAILURE, "Error", "Synthetic failure.", "", 3600, TRUE);
    if (problem == NULL && (gtk_widget_get_visible(hud.clock) ||
                            g_strcmp0(gtk_label_get_text(GTK_LABEL(hud.detail)), "Synthetic failure.") != 0))
        problem = "the compact error card lost its status or retained a clock.";
    jsti_hud_show_duration(HUD_FAILURE, "Something went wrong", "Synthetic failure.", "", 3600);
    hud_wait();
    GSource *hide_source = g_main_context_find_source_by_id(NULL, hud.hide);
    const gint64 remaining = hide_source != NULL ? g_source_get_ready_time(hide_source) - g_get_monotonic_time() : -1;
    if (problem == NULL && (remaining < 3000000 || remaining > 3600000))
        problem = "the shortened error timer was not scheduled.";
    guint64 previous_generation = hud.generation;
    jsti_hud_show_duration(HUD_FAILURE, "Something went wrong", "Synthetic failure.", "", 6000);
    hud_hide_later(&previous_generation);
    hide_source = g_main_context_find_source_by_id(NULL, hud.hide);
    const gint64 standard_remaining = hide_source != NULL
        ? g_source_get_ready_time(hide_source) - g_get_monotonic_time() : -1;
    if (problem == NULL && (jsti_hud_card() == NULL || standard_remaining < 5000000 ||
                            standard_remaining > 6000000))
        problem = "an old short error timer hid a replacement error or changed its duration.";
    previous_generation = hud.generation;
    jsti_hud_show(HUD_RECORDING, "Recording", "Capturing audio", "");
    hud_hide_later(&previous_generation);
    if (problem == NULL && (jsti_hud_card() == NULL || hud.phase != HUD_RECORDING || hud.hide != 0))
        problem = "an old error timer hid an active recording.";
    jsti_hud_show(HUD_HIDDEN, "", "", "");
    if (problem == NULL && jsti_hud_card() != NULL) problem = "hiding the HUD left it on screen.";
    jsti_hud_destroy();
    if (problem == NULL && (hud.window != NULL || hud.tick != 0 || hud.hide != 0))
        problem = "shutdown left the HUD or its timers alive.";
    if (problem != NULL) {
        jsti_set_error(error, capacity, "Recording HUD: %s", problem);
        result = -1;
    }
    return result;
}
