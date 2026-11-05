#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <math.h>

/* Only a small, declarative palette is read. Never load theme scripts or CSS.
 * Sandboxed desktops without this file retain the standard portal appearance. */
typedef struct { GdkRGBA background, foreground, accent; gboolean dark; } Palette;
static GtkCssProvider *provider;
static char *palette_path;
static GFileMonitor *directory_monitor, *file_monitor;
static guint reload_source;

static double luminance(GdkRGBA c) {
    double values[] = { c.red, c.green, c.blue };
    for (int i = 0; i < 3; ++i)
        values[i] = values[i] <= 0.04045 ? values[i] / 12.92 : pow((values[i] + 0.055) / 1.055, 2.4);
    return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722;
}

static double contrast(GdkRGBA a, GdkRGBA b) {
    double x = luminance(a), y = luminance(b);
    return (MAX(x, y) + 0.05) / (MIN(x, y) + 0.05);
}

static gboolean read_color(GKeyFile *keys, const char *name, GdkRGBA *color) {
    char *value = g_key_file_get_string(keys, "palette", name, NULL);
    gboolean valid = value != NULL;
    if (valid) {
        g_strstrip(value);
        valid = strlen(value) == 9 && value[0] == '"' && value[1] == '#' && value[8] == '"';
        for (int i = 2; valid && i < 8; ++i) valid = g_ascii_isxdigit(value[i]);
        if (valid) { value[8] = 0; valid = gdk_rgba_parse(color, value + 1); }
    }
    g_free(value);
    return valid;
}

static gboolean parse_palette(const char *text, Palette *palette) {
    GKeyFile *keys = g_key_file_new();
    char *ini = g_strconcat("[palette]\n", text, NULL);
    gboolean okay = g_key_file_load_from_data(keys, ini, -1, G_KEY_FILE_NONE, NULL);
    g_free(ini);
    char *mode = g_key_file_get_string(keys, "palette", "mode", NULL);
    okay = okay && (g_strcmp0(mode, "\"dark\"") == 0 || g_strcmp0(mode, "\"light\"") == 0)
        && read_color(keys, "background", &palette->background)
        && read_color(keys, "foreground", &palette->foreground)
        && read_color(keys, "accent", &palette->accent);
    palette->dark = g_strcmp0(mode, "\"dark\"") == 0;
    /* Refuse unreadable/inconsistent themes, rather than weakening text contrast. */
    okay = okay && contrast(palette->background, palette->foreground) >= 4.5
        && contrast(palette->background, palette->accent) >= 4.5
        && (luminance(palette->background) < 0.5) == palette->dark;
    g_free(mode);
    g_key_file_unref(keys);
    return okay;
}

static void apply_palette(void) {
    Palette palette = { 0 };
    AdwStyleManager *manager = adw_style_manager_get_default();
    if (adw_style_manager_get_high_contrast(manager)) {
        gtk_css_provider_load_from_string(provider,
            ".jsti-hero, .jsti-card, .jsti-history-row { border-color: currentColor; }"
            ".jsti-card-icon, .jsti-tint-accent, .jsti-tint-lagoon { color: @window_fg_color; }"
            "button.suggested-action, .jsti-record-hero { background-color: @window_fg_color; color: @window_bg_color; }"
            ".jsti-chip, .jsti-stat, .jsti-transcript-box { background-color: @view_bg_color; color: @view_fg_color; }");
        return;
    }
    char contents[16385];
    gsize count = 0;
    gboolean okay = FALSE;
    if (g_file_test(palette_path, G_FILE_TEST_IS_REGULAR)) {
        GFile *file = g_file_new_for_path(palette_path);
        GFileInputStream *stream = g_file_read(file, NULL, NULL);
        if (stream != NULL) {
            okay = g_input_stream_read_all(G_INPUT_STREAM(stream), contents, sizeof contents - 1, &count, NULL, NULL);
            g_object_unref(stream);
        }
        g_object_unref(file);
        contents[count] = 0;
        okay = okay && count < sizeof contents - 1 && parse_palette(contents, &palette)
            && palette.dark == adw_style_manager_get_dark(manager);
    }
    if (!okay) { gtk_css_provider_load_from_string(provider, ""); return; }
    char *bg = gdk_rgba_to_string(&palette.background), *fg = gdk_rgba_to_string(&palette.foreground);
    char *accent = gdk_rgba_to_string(&palette.accent);
    const GdkRGBA black = {0, 0, 0, 1}, white = {1, 1, 1, 1};
    const char *accent_fg = contrast(palette.accent, black) >= contrast(palette.accent, white) ? "#000000" : "#ffffff";
    /* Both names support our existing native bridges; variables style Adwaita's
     * standard controls, which use CSS custom properties in recent versions. */
    char *css = g_strdup_printf(
        "@define-color window_bg_color %s; @define-color window_fg_color %s;"
        "@define-color card_bg_color %s; @define-color card_fg_color %s;"
        "@define-color accent_bg_color %s; @define-color accent_fg_color %s; @define-color accent_color %s;"
        ":root { --window-bg-color: %s; --window-fg-color: %s; --view-bg-color: %s; --view-fg-color: %s;"
        " --card-bg-color: %s; --card-fg-color: %s; --headerbar-bg-color: %s; --headerbar-fg-color: %s;"
        " --sidebar-bg-color: %s; --sidebar-fg-color: %s; --accent-bg-color: %s; --accent-fg-color: %s; --accent-color: %s; }",
        bg, fg, bg, fg, accent, accent_fg, accent, bg, fg, bg, fg, bg, fg, bg, fg, bg, fg, accent, accent_fg, accent);
    gtk_css_provider_load_from_string(provider, css);
    g_free(css); g_free(bg); g_free(fg); g_free(accent);
}

static void changed(GFileMonitor *monitor, GFile *file, GFile *other, GFileMonitorEvent event, gpointer data);

static gboolean reload(gpointer data) {
    (void)data;
    reload_source = 0;
    /* Theme switches replace the directory/symlink. Reattach to the new file. */
    g_clear_object(&file_monitor);
    GFile *file = g_file_new_for_path(palette_path);
    file_monitor = g_file_monitor_file(file, G_FILE_MONITOR_NONE, NULL, NULL);
    g_object_unref(file);
    if (file_monitor) g_signal_connect(file_monitor, "changed", G_CALLBACK(changed), NULL);
    apply_palette();
    return G_SOURCE_REMOVE;
}

static void changed(GFileMonitor *monitor, GFile *file, GFile *other, GFileMonitorEvent event, gpointer data) {
    (void)monitor; (void)file; (void)other; (void)event; (void)data;
    if (!reload_source) reload_source = g_timeout_add(100, reload, NULL);
}

static void appearance_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    apply_palette();
}

void jsti_desktop_palette_install(void) {
    if (provider) return;
    palette_path = g_build_filename(g_get_user_state_dir(), "omarchy", "current", "theme", "colors.toml", NULL);
    char *current = g_build_filename(g_get_user_state_dir(), "omarchy", "current", NULL);
    GFile *directory = g_file_new_for_path(current);
    g_free(current);
    directory_monitor = g_file_monitor_directory(directory, G_FILE_MONITOR_NONE, NULL, NULL);
    g_object_unref(directory);
    if (directory_monitor) g_signal_connect(directory_monitor, "changed", G_CALLBACK(changed), NULL);
    provider = gtk_css_provider_new();
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 2);
    AdwStyleManager *manager = adw_style_manager_get_default();
    g_signal_connect(manager, "notify::dark", G_CALLBACK(appearance_changed), NULL);
    g_signal_connect(manager, "notify::high-contrast", G_CALLBACK(appearance_changed), NULL);
    reload(NULL);
}

int32_t jsti_desktop_palette_self_test(char *error, size_t capacity) {
    Palette palette = {0};
    const char *valid = "mode=\"dark\"\nbackground=\"#1a1b26\"\nforeground=\"#a9b1d6\"\naccent=\"#7aa2f7\"\n";
    if (!parse_palette(valid, &palette) || !palette.dark || contrast(palette.foreground, palette.background) < 4.5
        || parse_palette("mode=\"dark\"\nbackground=\"#111111\"\nforeground=\"#121212\"\naccent=\"#ffffff\"", &palette)
        || parse_palette("mode=\"dark\"\nbackground=\"#111111\"\nforeground=\"#ffffff\"\naccent=\"red; }\"", &palette)
        || parse_palette("background=\"#111111\"", &palette)) {
        jsti_set_error(error, capacity, "Desktop palette contrast or invalid-input fallback failed.");
        return -1;
    }
    if (!parse_palette("mode=\"light\"\nbackground=\"#ffffff\"\nforeground=\"#111111\"\naccent=\"#204a87\"", &palette)
        || palette.dark) {
        jsti_set_error(error, capacity, "Light desktop palette failed.");
        return -1;
    }
    return 0;
}
