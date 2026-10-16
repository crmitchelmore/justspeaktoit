#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>

static gchar *theme_root;
static GdkPixbuf *artwork;
static const char *app_icon_name = "com.justspeaktoit.JustSpeakToIt";

int32_t jsti_app_icon_configure(const char *root, char *error, size_t capacity) {
    if (root == NULL || !g_path_is_absolute(root)) {
        jsti_set_error(error, capacity, "The bundled application icon theme path must be absolute.");
        return -1;
    }
    gchar *path = g_build_filename(root, "hicolor", "256x256", "apps",
                                  "com.justspeaktoit.JustSpeakToIt.png", NULL);
    GError *failure = NULL;
    GdkPixbuf *next = gdk_pixbuf_new_from_file(path, &failure);
    g_free(path);
    if (next == NULL) {
        jsti_set_error(error, capacity, "Could not load the canonical application icon: %s", failure->message);
        g_error_free(failure);
        return -1;
    }
    if (gdk_pixbuf_get_width(next) != 256 || gdk_pixbuf_get_height(next) != 256 ||
        !gdk_pixbuf_get_has_alpha(next)) {
        g_object_unref(next);
        jsti_set_error(error, capacity, "The canonical application icon must be 256px RGBA.");
        return -1;
    }
    g_clear_object(&artwork);
    g_free(theme_root);
    artwork = next;
    theme_root = g_strdup(root);
    return 0;
}

void jsti_app_icon_install(void) {
    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gdk_display_get_default());
    gtk_icon_theme_add_search_path(theme, theme_root);
    gtk_window_set_default_icon_name(app_icon_name);
}

void jsti_app_icon_clear(void) {
    g_clear_object(&artwork);
    g_clear_pointer(&theme_root, g_free);
}

void jsti_brand_icon_paint(cairo_t *cr, double size) {
    g_return_if_fail(artwork != NULL);
    cairo_save(cr);
    cairo_scale(cr, size / gdk_pixbuf_get_width(artwork), size / gdk_pixbuf_get_height(artwork));
    gdk_cairo_set_source_pixbuf(cr, artwork, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BEST);
    cairo_paint(cr);
    cairo_restore(cr);
}
