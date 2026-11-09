#include "LinuxSupportInternal.h"

#include <adwaita.h>
#include <math.h>

/* Native desktop surfaces: colour comes from libadwaita/the desktop, with
 * optional read-only Omarchy palette integration. Brand identity stays in the
 * application icon; content does not need a large, permanently saturated hero. */
static const char *shared_css =
    "@define-color jsti_lagoon @accent_color;\n"
    "@define-color jsti_green @success_color;\n"
    "@define-color jsti_blue @accent_color;\n"
    "@define-color jsti_orange @warning_color;\n"
    ".jsti-root { background-color: @window_bg_color; }\n"
    ".jsti-root .dim-label, .jsti-root windowtitle .subtitle { opacity: 0.85; }\n"
    ".jsti-sidebar-heading { font-size: 12px; font-weight: 700; margin: 12px 12px 4px; }\n"
    ".jsti-sidebar row { border-radius: 6px; margin: 1px 6px; padding: 7px 10px; }\n"
    ".jsti-sidebar row.jsti-settings-row { margin-left: 16px; }\n"
    ".jsti-sidebar row:selected { background-color: alpha(@accent_bg_color, 0.16); }\n"
    ".jsti-sidebar row:selected label { font-weight: 700; }\n"
    ".jsti-sidebar image { margin-right: 4px; }\n"
    ".jsti-tint-lagoon, .jsti-tint-accent { color: @accent_color; }\n"
    ".jsti-tint-green { color: @success_color; }\n"
    ".jsti-tint-warm { color: @warning_color; }\n"
    ".jsti-hero { background-color: @card_bg_color; color: @card_fg_color;"
    " border: 1px solid alpha(currentColor, 0.16); border-radius: 10px; padding: 18px; }\n"
    ".jsti-hero-title { font-size: 22px; font-weight: 700; }\n"
    ".jsti-hero-subtitle { font-weight: 400; }\n"
    ".jsti-chip { background-color: alpha(currentColor, 0.05); border-radius: 6px; padding: 8px 12px; }\n"
    ".jsti-chip-label { font-size: 11px; font-weight: 600; }\n"
    ".jsti-chip-value { font-size: 18px; font-weight: 700; }\n"
    ".jsti-hero entry { border-radius: 6px; min-height: 36px; }\n"
    ".jsti-hero-button { border-radius: 6px; font-weight: 600; padding: 6px 12px; }\n"
    ".jsti-record-hero { background-color: @accent_bg_color; color: @accent_fg_color;"
    " border-radius: 6px; padding: 10px 18px; font-weight: 700; font-size: 14px; }\n"
    ".jsti-record-hero:hover { background-image: linear-gradient(alpha(currentColor, 0.08), alpha(currentColor, 0.08)); }\n"
    ".jsti-record-hero.recording { background-color: @error_bg_color; color: @error_fg_color; }\n"
    ".jsti-record-hero:disabled { opacity: 0.5; }\n"
    ".jsti-live-preview { background-color: alpha(currentColor, 0.05); border-radius: 6px; padding: 10px 12px; }\n"
    ".jsti-card { background-color: @card_bg_color; color: @card_fg_color; border-radius: 8px; padding: 16px;"
    " border: 1px solid alpha(currentColor, 0.12); }\n"
    ".jsti-card-icon { color: @accent_color; min-width: 28px; min-height: 28px; }\n"
    ".jsti-card-title { font-size: 16px; font-weight: 700; }\n"
    ".jsti-stat { background-color: alpha(currentColor, 0.04); border-radius: 6px; padding: 10px 12px; }\n"
    ".jsti-stat-label { font-size: 12px; }\n"
    ".jsti-stat-value { font-size: 18px; font-weight: 700; }\n"
    ".jsti-setup-tile { background-color: alpha(currentColor, 0.04); border-radius: 6px; padding: 10px 12px; }\n"
    ".jsti-setup-tile.attention { border: 1px solid @warning_color; }\n"
    ".jsti-setup-title { font-weight: 600; }\n"
    ".jsti-setup-detail { font-size: 12px; }\n"
    ".jsti-dot { min-width: 10px; min-height: 10px; border-radius: 5px; background-color: @success_color; }\n"
    ".attention .jsti-dot { background-color: @warning_color; }\n"
    ".jsti-transcript, .jsti-transcript text { background-color: transparent; }\n"
    ".jsti-transcript-box { background-color: alpha(currentColor, 0.04); border-radius: 6px; padding: 12px; }\n"
    "list.jsti-history { background-color: transparent; }\n"
    "list.jsti-history > row { padding: 0; margin: 0 0 8px; background-color: transparent; border-radius: 8px; }\n"
    "list.jsti-history > row:focus-visible { outline-offset: -2px; }\n"
    ".jsti-history-row { background-color: @card_bg_color; color: @card_fg_color; border-radius: 8px; padding: 16px;"
    " border: 1px solid alpha(currentColor, 0.16); }\n"
    ".jsti-history-row.failed { border-color: @warning_color; }\n"
    "list.jsti-history > row:selected .jsti-history-row { border-color: @accent_color; background-color: alpha(@accent_bg_color, 0.12); }\n"
    ".jsti-history-preview { font-size: 14px; }\n"
    ".jsti-history-models { font-size: 12px; }\n"
    ".jsti-badge { border-radius: 4px; padding: 4px 8px; background-color: alpha(currentColor, 0.05); }\n"
    ".jsti-badge.error { color: @warning_color; }\n"
    ".jsti-badge-title { font-size: 11px; font-weight: 600; }\n"
    ".jsti-badge-value { font-size: 12px; font-weight: 600; }\n"
    ".jsti-detail-heading { font-weight: 700; margin-top: 4px; }\n"
    ".jsti-statusbar { padding: 8px 16px; border-top: 1px solid alpha(currentColor, 0.16); }\n"
    ".jsti-statusbar label { font-size: 13px; }\n"
    ".jsti-empty { padding: 16px; }\n"
    ".jsti-about-name { font-size: 22px; font-weight: 700; }\n";

void jsti_style_install(void) {
    static gboolean installed;
    GdkDisplay *display = gdk_display_get_default();
    if (display == NULL || installed) return;
    installed = TRUE;
    GtkCssProvider *shared = gtk_css_provider_new();
    gtk_css_provider_load_from_string(shared, shared_css);
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(shared),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(shared);
    jsti_desktop_palette_install();
}

/* ------------------------------------------------------------ brand icon */

static void draw_brand_icon(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area; (void)data;
    double size = MIN(width, height);
    cairo_translate(cr, (width - size) / 2, (height - size) / 2);
    jsti_brand_icon_paint(cr, size);
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

static JSTIVisualDensity visual_density;
static GtkCssProvider *density_provider;

enum { DENSITY_INLINE = 1, DENSITY_PAGE, DENSITY_CARD, DENSITY_CONTENT };

static void density_project_box(GtkWidget *widget) {
    const gint role = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "jsti-density-role"));
    if (role == 0) return;
    const gint original = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "jsti-density-spacing")) - 1;
    gint spacing = visual_density.inline_spacing;
    if (role == DENSITY_PAGE) spacing = visual_density.section_spacing;
    if (role == DENSITY_CARD) spacing = visual_density.group_spacing;
    if (role == DENSITY_CONTENT) spacing = visual_density.content_spacing;
    gtk_box_set_spacing(GTK_BOX(widget), visual_density.compact ? MIN(original, spacing) : original);
    if (role == DENSITY_PAGE) {
        const gint margin = visual_density.compact ? visual_density.page_padding : 24;
        gtk_widget_set_margin_top(widget, margin);
        gtk_widget_set_margin_bottom(widget, margin);
        gtk_widget_set_margin_start(widget, margin);
        gtk_widget_set_margin_end(widget, margin);
    }
}

static GtkWidget *density_box_new(GtkOrientation orientation, gint spacing, gint role) {
    GtkWidget *widget = gtk_box_new(orientation, spacing);
    g_object_set_data(G_OBJECT(widget), "jsti-density-role", GINT_TO_POINTER(role));
    g_object_set_data(G_OBJECT(widget), "jsti-density-spacing", GINT_TO_POINTER(spacing + 1));
    density_project_box(widget);
    return widget;
}

static void density_project_tree(GtkWidget *widget) {
    density_project_box(widget);
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child != NULL;
         child = gtk_widget_get_next_sibling(child)) density_project_tree(child);
}

void jsti_visual_density_apply(GtkWidget *root, const JSTIVisualDensity *density) {
    visual_density = *density;
    if (density_provider == NULL) {
        density_provider = gtk_css_provider_new();
        gtk_style_context_add_provider_for_display(gtk_widget_get_display(root),
            GTK_STYLE_PROVIDER(density_provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    }
    gchar *css = g_strdup_printf(
        ".jsti-density-compact .jsti-card, .jsti-density-compact .jsti-hero { padding: %dpx; }\n"
        ".jsti-density-compact .jsti-chip, .jsti-density-compact .jsti-stat,"
        " .jsti-density-compact .jsti-setup-tile { padding: %dpx %dpx; }\n"
        ".jsti-density-compact .jsti-history-row { padding: %dpx; }\n"
        ".jsti-density-compact list.jsti-history > row { margin-bottom: %dpx; }\n"
        ".jsti-density-compact .jsti-sidebar row { min-height: %dpx; padding-top: 0; padding-bottom: 0; }\n"
        ".jsti-density-compact .jsti-sidebar-heading { margin-top: %dpx; margin-left: %dpx; }\n",
        density->card_padding, density->inline_spacing, density->card_padding,
        density->card_padding, density->section_spacing, MAX(44, density->minimum_row_height),
        density->group_spacing, density->page_padding);
    gtk_css_provider_load_from_string(density_provider, css);
    g_free(css);
    if (density->compact) gtk_widget_add_css_class(root, "jsti-density-compact");
    else gtk_widget_remove_css_class(root, "jsti-density-compact");
    density_project_tree(root);
}

typedef struct {
    GtkWidget *widget;
    gint spacing, margin, minimum, natural;
} DensityGeometry;

static void density_snapshot(GtkWidget *widget, GArray *snapshot) {
    const gint role = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "jsti-density-role"));
    if (role != 0) {
        DensityGeometry item = { widget, gtk_box_get_spacing(GTK_BOX(widget)), gtk_widget_get_margin_top(widget), 0, 0 };
        gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, 500, &item.minimum, &item.natural, NULL, NULL);
        g_array_append_val(snapshot, item);
    }
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child != NULL;
         child = gtk_widget_get_next_sibling(child)) density_snapshot(child, snapshot);
}

static gboolean density_sidebar_targets(GtkWidget *widget) {
    if (GTK_IS_LIST_BOX_ROW(widget) &&
        gtk_widget_has_css_class(gtk_widget_get_parent(widget), "jsti-sidebar")) {
        gint minimum = 0;
        gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, -1, &minimum, NULL, NULL, NULL);
        if (minimum < MAX(44, visual_density.minimum_row_height)) return FALSE;
    }
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child != NULL;
         child = gtk_widget_get_next_sibling(child))
        if (!density_sidebar_targets(child)) return FALSE;
    return TRUE;
}

int32_t jsti_visual_density_self_test(GtkWidget *root) {
    const JSTIVisualDensity saved = visual_density;
    JSTIVisualDensity normal = saved;
    normal.compact = 0;
    const JSTIVisualDensity compact = { 1, 8, 6, 8, 6, 6, 8, 30 };
    GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(root));
    gchar *text = GTK_IS_EDITABLE(focus) ? g_strdup(gtk_editable_get_text(GTK_EDITABLE(focus))) : NULL;
    jsti_visual_density_apply(root, &normal);
    GArray *snapshot = g_array_new(FALSE, FALSE, sizeof(DensityGeometry));
    density_snapshot(root, snapshot);
    jsti_visual_density_apply(root, &compact);
    gboolean okay = snapshot->len > 0;
    guint pages = 0, cards = 0, measured_cards = 0;
    for (guint index = 0; index < snapshot->len; ++index) {
        const DensityGeometry *item = &g_array_index(snapshot, DensityGeometry, index);
        const gint role = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item->widget), "jsti-density-role"));
        const gint spacing = gtk_box_get_spacing(GTK_BOX(item->widget));
        okay = okay && spacing <= item->spacing;
        if (role == DENSITY_PAGE) {
            pages++;
            okay = okay && item->spacing == 20 && item->margin == 24 && spacing == 6 &&
                gtk_widget_get_margin_top(item->widget) == 8 && gtk_widget_get_margin_bottom(item->widget) == 8 &&
                gtk_widget_get_margin_start(item->widget) == 8 && gtk_widget_get_margin_end(item->widget) == 8;
        }
        if (role == DENSITY_CARD) {
            cards++;
            gint minimum = 0, natural = 0;
            gtk_widget_measure(item->widget, GTK_ORIENTATION_VERTICAL, 500, &minimum, &natural, NULL, NULL);
            okay = okay && item->spacing == 16 && spacing == 8 &&
                minimum <= item->minimum && natural <= item->natural;
            if (natural < item->natural) measured_cards++;
        }
    }
    okay = okay && density_sidebar_targets(root);
    jsti_visual_density_apply(root, &normal);
    for (guint index = 0; index < snapshot->len; ++index) {
        const DensityGeometry *item = &g_array_index(snapshot, DensityGeometry, index);
        gint minimum = 0, natural = 0;
        gtk_widget_measure(item->widget, GTK_ORIENTATION_VERTICAL, 500, &minimum, &natural, NULL, NULL);
        okay = okay && gtk_box_get_spacing(GTK_BOX(item->widget)) == item->spacing &&
            gtk_widget_get_margin_top(item->widget) == item->margin &&
            minimum == item->minimum && natural == item->natural;
    }
    okay = okay && pages > 0 && cards > 0 && measured_cards > 0 &&
        gtk_window_get_focus(GTK_WINDOW(root)) == focus;
    if (text != NULL) okay = okay && g_strcmp0(text, gtk_editable_get_text(GTK_EDITABLE(focus))) == 0;
    g_free(text);
    g_array_unref(snapshot);
    jsti_visual_density_apply(root, &saved);
    return okay ? 0 : -1;
}

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
    GtkWidget *column = density_box_new(GTK_ORIENTATION_VERTICAL, 20, DENSITY_PAGE);
    adw_clamp_set_child(ADW_CLAMP(clamp), column);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), clamp);
    *content = column;
    return scroller;
}

GtkWidget *jsti_hero_new(const char *variant, const char *title, const char *subtitle, GtkWidget **chips,
                         GtkWidget **trailing) {
    GtkWidget *hero = density_box_new(GTK_ORIENTATION_VERTICAL, 18, DENSITY_CONTENT);
    gtk_widget_add_css_class(hero, "jsti-hero");
    if (variant != NULL) gtk_widget_add_css_class(hero, variant);
    GtkWidget *top = density_box_new(GTK_ORIENTATION_HORIZONTAL, 18, DENSITY_INLINE);
    gtk_widget_add_css_class(top, "jsti-hero-header");
    GtkWidget *text = density_box_new(GTK_ORIENTATION_VERTICAL, 6, DENSITY_INLINE);
    gtk_widget_set_hexpand(text, TRUE);
    gtk_box_append(GTK_BOX(text), label_with(title, "jsti-hero-title"));
    gtk_box_append(GTK_BOX(text), label_with(subtitle, "jsti-hero-subtitle"));
    gtk_box_append(GTK_BOX(top), text);
    GtkWidget *slot = density_box_new(GTK_ORIENTATION_HORIZONTAL, 8, DENSITY_INLINE);
    gtk_widget_set_valign(slot, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(top), slot);
    gtk_box_append(GTK_BOX(hero), top);
    GtkWidget *row = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(row), GTK_SELECTION_NONE);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(row), 12);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(row), 12);
    gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(row), 1);
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
    GtkWidget *card = density_box_new(GTK_ORIENTATION_VERTICAL, 16, DENSITY_CARD);
    gtk_widget_add_css_class(card, "jsti-card");
    GtkWidget *header = density_box_new(GTK_ORIENTATION_HORIZONTAL, 12, DENSITY_INLINE);
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
    GtkWidget *content = density_box_new(GTK_ORIENTATION_VERTICAL, 12, DENSITY_CONTENT);
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
