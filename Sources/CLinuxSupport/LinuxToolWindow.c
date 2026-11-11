/* Tool windows over the main window, such as Permissions and Troubleshooting. */
#include "LinuxSupportInternal.h"
#include <adwaita.h>

static gboolean tool_window_key(GtkEventControllerKey *controller, guint key, guint code,
                                GdkModifierType modifiers, gpointer data) {
    (void)code; (void)modifiers; (void)data;
    if (key != GDK_KEY_Escape) return FALSE;
    gtk_window_close(GTK_WINDOW(gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller))));
    return TRUE;
}

GtkWindow *jsti_tool_window_new(GtkWindow *owner, const char *title, int height, GtkWidget **column) {
    GtkWindow *window = GTK_WINDOW(adw_window_new());
    gtk_window_set_title(window, title);
    gtk_window_set_default_size(window, 620, height);
    gtk_window_set_transient_for(window, owner);
    gtk_window_set_destroy_with_parent(window, TRUE);
    gtk_window_set_application(window, gtk_window_get_application(owner));
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(tool_window_key), NULL);
    gtk_widget_add_controller(GTK_WIDGET(window), keys);
    GtkWidget *toolbar = adw_toolbar_view_new();
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar), adw_header_bar_new());
    *column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_margin_start(*column, 20); gtk_widget_set_margin_end(*column, 20);
    gtk_widget_set_margin_top(*column, 16); gtk_widget_set_margin_bottom(*column, 20);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), *column);
    adw_window_set_content(ADW_WINDOW(window), toolbar);
    return window;
}
