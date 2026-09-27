#include "LinuxSupportInternal.h"

#include <adwaita.h>
#include <math.h>

/*
 * The app's look. Colours are the Mac app's brand tokens (SpeakCore
 * BrandColors: accent #FF6B3D, warm #FF9C4A, deep #E3522E, lagoon #2ED4BF);
 * shapes follow its density tokens (cards radius 28, heroes 32, chips 20,
 * page padding 24). Everything else comes from libadwaita, so the window
 * follows the desktop's light or dark style and its fonts.
 */

static const char *shared_css =
    "@define-color accent_bg_color #E3522E;\n"
    "@define-color accent_fg_color #ffffff;\n"
    "@define-color jsti_lagoon #1AAB99;\n"
    "@define-color jsti_green #26A269;\n"
    "@define-color jsti_blue #3584E4;\n"
    "@define-color jsti_orange #E66100;\n"
    ".jsti-root { background-color: @window_bg_color; }\n"
    ".jsti-page { background-image: linear-gradient(180deg, alpha(#FF6B3D, 0.07), alpha(#FF6B3D, 0) 360px); }\n"
    ".jsti-sidebar-heading { font-size: 12px; font-weight: 700; opacity: 0.55; margin: 12px 12px 4px 12px; }\n"
    ".jsti-sidebar row { border-radius: 10px; margin: 1px 6px; padding: 7px 10px; }\n"
    ".jsti-sidebar row.jsti-settings-row { margin-left: 16px; }\n"
    ".jsti-sidebar row:selected { background-color: alpha(@accent_bg_color, 0.16); }\n"
    ".jsti-sidebar row:selected label { font-weight: 700; }\n"
    ".jsti-sidebar image { margin-right: 4px; }\n"
    ".jsti-tint-lagoon { color: @jsti_lagoon; }\n"
    ".jsti-tint-accent { color: #E3522E; }\n"
    ".jsti-tint-green { color: @jsti_green; }\n"
    ".jsti-tint-warm { color: #F08A2C; }\n"
    ".jsti-hero { background-image: linear-gradient(120deg, #E3522E, alpha(#FF9C4A, 0.92));"
    " border-radius: 30px; padding: 28px; color: #ffffff;"
    " box-shadow: 0 16px 28px -14px alpha(#E3522E, 0.55); }\n"
    ".jsti-hero.voice { background-image: linear-gradient(120deg, #1F9D55, alpha(#3CCF9E, 0.85));"
    " box-shadow: 0 16px 28px -14px alpha(#1F9D55, 0.5); }\n"
    ".jsti-hero.settings { background-image: linear-gradient(120deg, #F07A1A, alpha(#F7A64A, 0.8));"
    " box-shadow: 0 16px 28px -14px alpha(#F07A1A, 0.5); }\n"
    ".jsti-hero-title { font-size: 28px; font-weight: 800; }\n"
    ".jsti-hero-subtitle { font-weight: 600; color: alpha(#ffffff, 0.88); }\n"
    ".jsti-chip { background-color: alpha(#ffffff, 0.16); border-radius: 20px; padding: 12px 18px; }\n"
    ".jsti-chip-label { font-size: 11px; font-weight: 700; color: alpha(#ffffff, 0.82); }\n"
    ".jsti-chip-value { font-size: 20px; font-weight: 800; }\n"
    ".jsti-hero entry, .jsti-hero searchbar entry { background-color: alpha(#ffffff, 0.18); color: #ffffff;"
    " border-radius: 18px; min-height: 40px; }\n"
    ".jsti-hero entry image, .jsti-hero entry text { color: #ffffff; }\n"
    ".jsti-hero-button { background-color: alpha(#ffffff, 0.2); color: #ffffff; border-radius: 12px;"
    " font-weight: 700; padding: 6px 14px; }\n"
    ".jsti-hero-button:hover { background-color: alpha(#ffffff, 0.3); }\n"
    ".jsti-record-hero { background-image: linear-gradient(180deg, #2D8CFF, #0A6CFF); color: #ffffff;"
    " border-radius: 999px; padding: 14px 30px; font-weight: 800; font-size: 15px;"
    " box-shadow: 0 10px 20px -10px alpha(#0A6CFF, 0.8); }\n"
    ".jsti-record-hero:hover { background-image: linear-gradient(180deg, #4A9DFF, #1F79FF); }\n"
    ".jsti-record-hero.recording { background-image: linear-gradient(180deg, #FF5A5A, #D92A2A);"
    " box-shadow: 0 10px 20px -10px alpha(#D92A2A, 0.8); }\n"
    ".jsti-record-hero:disabled { background-image: none; background-color: alpha(#ffffff, 0.25);"
    " color: alpha(#ffffff, 0.8); box-shadow: none; }\n"
    ".jsti-live-preview { background-color: alpha(#ffffff, 0.12); border-radius: 18px; padding: 12px 16px;"
    " font-family: monospace; }\n"
    ".jsti-card { background-color: @card_bg_color; border-radius: 26px; padding: 22px;"
    " border: 1px solid alpha(@accent_bg_color, 0.14);"
    " box-shadow: 0 12px 24px -18px alpha(@accent_bg_color, 0.45), 0 1px 2px alpha(#000000, 0.06); }\n"
    ".jsti-card-icon { background-color: alpha(@accent_bg_color, 0.15); color: #E3522E; border-radius: 14px;"
    " min-width: 40px; min-height: 40px; }\n"
    ".jsti-card-title { font-size: 16px; font-weight: 700; }\n"
    ".jsti-stat { background-color: alpha(@accent_bg_color, 0.08); border-radius: 18px; padding: 14px 16px; }\n"
    ".jsti-stat-label { font-size: 12px; opacity: 0.72; }\n"
    ".jsti-stat-value { font-size: 20px; font-weight: 800; }\n"
    ".jsti-setup-tile { background-color: alpha(currentColor, 0.04); border-radius: 18px; padding: 12px 14px;"
    " border: 1px solid alpha(@jsti_green, 0.45); }\n"
    ".jsti-setup-tile.attention { border-color: alpha(@jsti_orange, 0.55); }\n"
    ".jsti-setup-title { font-weight: 700; }\n"
    ".jsti-setup-detail { font-size: 12px; opacity: 0.72; }\n"
    ".jsti-dot { min-width: 10px; min-height: 10px; border-radius: 5px; background-color: @jsti_green; }\n"
    ".attention .jsti-dot { background-color: @jsti_orange; }\n"
    ".jsti-transcript, .jsti-transcript text { font-family: monospace; background-color: transparent; }\n"
    ".jsti-transcript-box { background-color: alpha(currentColor, 0.05); border-radius: 16px; padding: 12px; }\n"
    "list.jsti-history { background-color: transparent; }\n"
    "list.jsti-history > row { padding: 0; margin: 0 0 12px 0; background-color: transparent;"
    " border-radius: 26px; }\n"
    "list.jsti-history > row:focus-visible { outline-offset: -2px; }\n"
    ".jsti-history-row { background-color: @card_bg_color; border-radius: 26px; padding: 18px 20px;"
    " border: 1px solid alpha(@accent_bg_color, 0.16);"
    " box-shadow: 0 8px 18px -16px alpha(@accent_bg_color, 0.5); }\n"
    ".jsti-history-row.failed { border-color: alpha(@jsti_orange, 0.5); }\n"
    "list.jsti-history > row:selected .jsti-history-row { border: 2px solid alpha(@accent_bg_color, 0.7); }\n"
    ".jsti-history-preview { font-size: 14px; }\n"
    ".jsti-history-models { font-size: 12px; opacity: 0.7; }\n"
    ".jsti-badge { border-radius: 12px; padding: 6px 10px; background-color: alpha(@jsti_blue, 0.13);"
    " color: @jsti_blue; }\n"
    ".jsti-badge.cost { background-color: alpha(@jsti_green, 0.14); color: @jsti_green; }\n"
    ".jsti-badge.error { background-color: alpha(@jsti_orange, 0.14); color: @jsti_orange; }\n"
    ".jsti-badge.context { background-color: alpha(@jsti_lagoon, 0.14); color: @jsti_lagoon; }\n"
    ".jsti-badge-title { font-size: 10px; font-weight: 800; }\n"
    ".jsti-badge-value { font-size: 12px; font-weight: 700; }\n"
    ".jsti-detail-heading { font-weight: 700; margin-top: 4px; }\n"
    ".jsti-statusbar { padding: 8px 16px; border-top: 1px solid alpha(currentColor, 0.1); }\n"
    ".jsti-statusbar label { font-size: 13px; }\n"
    ".jsti-empty { opacity: 0.7; padding: 24px; }\n"
    ".jsti-about-name { font-size: 22px; font-weight: 800; }\n";

/* Accent text needs more contrast on a dark surface. */
static const char *light_css = "@define-color accent_color #C4411F;\n";
static const char *dark_css = "@define-color accent_color #FF8A5C;\n"
                              ".jsti-card-icon { color: #FF8A5C; }\n"
                              ".jsti-tint-accent { color: #FF7A4D; }\n";

static GtkCssProvider *shade_provider;

static void apply_shade(AdwStyleManager *manager) {
    gtk_css_provider_load_from_string(shade_provider, adw_style_manager_get_dark(manager) ? dark_css : light_css);
}

static void on_dark_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)spec; (void)data;
    apply_shade(ADW_STYLE_MANAGER(object));
}

void jsti_style_install(void) {
    GdkDisplay *display = gdk_display_get_default();
    if (display == NULL || shade_provider != NULL) return;
    GtkCssProvider *shared = gtk_css_provider_new();
    gtk_css_provider_load_from_string(shared, shared_css);
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(shared),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(shared);
    shade_provider = gtk_css_provider_new();
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(shade_provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    AdwStyleManager *manager = adw_style_manager_get_default();
    apply_shade(manager);
    g_signal_connect(manager, "notify::dark", G_CALLBACK(on_dark_changed), NULL);
}

/* ------------------------------------------------------------ brand icon */

static void rounded_rectangle(cairo_t *cr, double x, double y, double width, double height, double radius) {
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + width - radius, y + radius, radius, -M_PI_2, 0);
    cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, M_PI_2);
    cairo_arc(cr, x + radius, y + height - radius, radius, M_PI_2, M_PI);
    cairo_arc(cr, x + radius, y + radius, radius, M_PI, 3 * M_PI_2);
    cairo_close_path(cr);
}

/* Resources/Brand/AppIcon.svg on a 1024 grid: an orange rounded square and
 * five dark bars. */
static void draw_brand_icon(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area; (void)data;
    double size = MIN(width, height), scale = size / 1024.0;
    cairo_translate(cr, (width - size) / 2, (height - size) / 2);
    cairo_scale(cr, scale, scale);
    cairo_pattern_t *surface = cairo_pattern_create_linear(0, 0, 0, 1024);
    cairo_pattern_add_color_stop_rgb(surface, 0, 1.0, 0.42, 0.24);
    cairo_pattern_add_color_stop_rgb(surface, 1, 1.0, 0.61, 0.29);
    rounded_rectangle(cr, 0, 0, 1024, 1024, 224);
    cairo_set_source(cr, surface);
    cairo_fill(cr);
    cairo_pattern_destroy(surface);
    static const double bars[5][2] = { { 224, 408 }, { 348, 328 }, { 472, 240 }, { 596, 328 }, { 720, 408 } };
    cairo_set_source_rgb(cr, 0x18 / 255.0, 0x1b / 255.0, 0x1d / 255.0);
    for (int index = 0; index < 5; index++) {
        double top = bars[index][1];
        rounded_rectangle(cr, bars[index][0], top, 80, 1024 - 2 * top, 40);
        cairo_fill(cr);
    }
}

GtkWidget *jsti_brand_icon_new(int size) {
    GtkWidget *area = gtk_drawing_area_new();
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(area), size);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), size);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), draw_brand_icon, NULL, NULL);
    gtk_widget_set_halign(area, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(area, GTK_ALIGN_CENTER);
    return area;
}

/* ------------------------------------------------------------- builders */

static GtkWidget *label_with(const char *text, const char *css_class) {
    GtkWidget *label = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    if (css_class != NULL) gtk_widget_add_css_class(label, css_class);
    return label;
}

GtkWidget *jsti_page_new(GtkWidget **content) {
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_add_css_class(scroller, "jsti-page");
    GtkWidget *clamp = adw_clamp_new();
    adw_clamp_set_maximum_size(ADW_CLAMP(clamp), 1000);
    adw_clamp_set_tightening_threshold(ADW_CLAMP(clamp), 760);
    GtkWidget *column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 20);
    gtk_widget_set_margin_top(column, 24);
    gtk_widget_set_margin_bottom(column, 24);
    gtk_widget_set_margin_start(column, 24);
    gtk_widget_set_margin_end(column, 24);
    adw_clamp_set_child(ADW_CLAMP(clamp), column);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), clamp);
    *content = column;
    return scroller;
}

GtkWidget *jsti_hero_new(const char *variant, const char *title, const char *subtitle, GtkWidget **chips,
                         GtkWidget **trailing) {
    GtkWidget *hero = gtk_box_new(GTK_ORIENTATION_VERTICAL, 18);
    gtk_widget_add_css_class(hero, "jsti-hero");
    if (variant != NULL) gtk_widget_add_css_class(hero, variant);
    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 18);
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_hexpand(text, TRUE);
    gtk_box_append(GTK_BOX(text), label_with(title, "jsti-hero-title"));
    gtk_box_append(GTK_BOX(text), label_with(subtitle, "jsti-hero-subtitle"));
    gtk_box_append(GTK_BOX(top), text);
    GtkWidget *slot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_valign(slot, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(top), slot);
    gtk_box_append(GTK_BOX(hero), top);
    GtkWidget *row = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(row), GTK_SELECTION_NONE);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(row), 12);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(row), 12);
    gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(row), 2);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(row), 4);
    gtk_flow_box_set_homogeneous(GTK_FLOW_BOX(row), TRUE);
    gtk_widget_set_can_target(row, TRUE);
    gtk_box_append(GTK_BOX(hero), row);
    if (chips != NULL) *chips = row;
    if (trailing != NULL) *trailing = slot;
    return hero;
}

GtkWidget *jsti_chip_new(const char *label, GtkLabel **value) {
    GtkWidget *chip = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(chip, "jsti-chip");
    gchar *upper = g_utf8_strup(label, -1);
    gtk_box_append(GTK_BOX(chip), label_with(upper, "jsti-chip-label"));
    g_free(upper);
    GtkWidget *number = label_with("—", "jsti-chip-value");
    gtk_widget_add_css_class(number, "numeric");
    gtk_box_append(GTK_BOX(chip), number);
    if (value != NULL) *value = GTK_LABEL(number);
    return chip;
}

GtkWidget *jsti_card_new(const char *icon, const char *title, GtkWidget **body) {
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_add_css_class(card, "jsti-card");
    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *tile = gtk_image_new_from_icon_name(icon);
    gtk_image_set_pixel_size(GTK_IMAGE(tile), 20);
    gtk_widget_add_css_class(tile, "jsti-card-icon");
    gtk_box_append(GTK_BOX(header), tile);
    GtkWidget *heading = label_with(title, "jsti-card-title");
    gtk_label_set_wrap(GTK_LABEL(heading), FALSE);
    gtk_widget_set_hexpand(heading, TRUE);
    gtk_widget_set_valign(heading, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(header), heading);
    gtk_box_append(GTK_BOX(card), header);
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_box_append(GTK_BOX(card), content);
    if (body != NULL) *body = content;
    return card;
}

GtkWidget *jsti_stat_new(const char *label, GtkLabel **value) {
    GtkWidget *stat = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(stat, "jsti-stat");
    gtk_box_append(GTK_BOX(stat), label_with(label, "jsti-stat-label"));
    GtkWidget *number = label_with("—", "jsti-stat-value");
    gtk_widget_add_css_class(number, "numeric");
    gtk_box_append(GTK_BOX(stat), number);
    if (value != NULL) *value = GTK_LABEL(number);
    return stat;
}

GtkWidget *jsti_badge_new(const char *kind, const char *icon, const char *title, const char *value) {
    GtkWidget *badge = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_widget_add_css_class(badge, "jsti-badge");
    if (kind != NULL) gtk_widget_add_css_class(badge, kind);
    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 5);
    GtkWidget *image = gtk_image_new_from_icon_name(icon);
    gtk_image_set_pixel_size(GTK_IMAGE(image), 12);
    gtk_box_append(GTK_BOX(header), image);
    gchar *upper = g_utf8_strup(title, -1);
    gtk_box_append(GTK_BOX(header), label_with(upper, "jsti-badge-title"));
    g_free(upper);
    gtk_box_append(GTK_BOX(badge), header);
    GtkWidget *text = label_with(value, "jsti-badge-value");
    gtk_label_set_wrap(GTK_LABEL(text), FALSE);
    gtk_label_set_ellipsize(GTK_LABEL(text), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(text), 28);
    gtk_label_set_width_chars(GTK_LABEL(text), 5);
    gtk_widget_add_css_class(text, "numeric");
    gtk_box_append(GTK_BOX(badge), text);
    gtk_widget_set_valign(badge, GTK_ALIGN_START);
    return badge;
}
