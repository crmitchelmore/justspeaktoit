#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>
#include <string.h>

typedef struct Model { gchar *id, *name; gboolean selected; } Model;
typedef struct Configuration { GPtrArray *models; gboolean errors; gchar *from, *through; } Configuration;
typedef struct Panel {
    GtkPopover *popover;
    GPtrArray *checks;
    GPtrArray *ids;
    GtkCheckButton *errors, *from_enabled, *through_enabled;
    GtkCalendar *from_calendar, *through_calendar;
} Panel;
static Configuration *configuration;
static GtkMenuButton *button;

static void model_free(gpointer pointer) {
    Model *model = pointer;
    g_free(model->id); g_free(model->name); g_free(model);
}
static void configuration_free(gpointer pointer) {
    Configuration *config = pointer;
    if (!config) return;
    g_ptr_array_unref(config->models);
    g_free(config->from); g_free(config->through); g_free(config);
}
static void panel_free(gpointer pointer) {
    Panel *panel = pointer;
    g_ptr_array_unref(panel->checks); g_ptr_array_unref(panel->ids); g_free(panel);
}
static void json_string(GString *output, const gchar *text) {
    g_string_append_c(output, '"');
    for (const guchar *byte = (const guchar *)text; *byte; ++byte) {
        if (*byte == '"' || *byte == '\\') { g_string_append_c(output, '\\'); g_string_append_c(output, *byte); }
        else if (*byte < 32) g_string_append_printf(output, "\\u%04x", *byte);
        else g_string_append_c(output, *byte);
    }
    g_string_append_c(output, '"');
}
static gchar *day(GtkCheckButton *enabled, GtkCalendar *calendar) {
    if (!gtk_check_button_get_active(enabled)) return g_strdup("");
    GDateTime *date = gtk_calendar_get_date(calendar);
    gchar *text = g_date_time_format(date, "%Y-%m-%d");
    g_date_time_unref(date);
    return text;
}
static gchar *serialize(Panel *panel) {
    GString *payload = g_string_new("{\"models\":[");
    gboolean first = TRUE;
    for (guint index = 0; index < panel->checks->len; ++index) {
        if (!gtk_check_button_get_active(g_ptr_array_index(panel->checks, index))) continue;
        if (!first) g_string_append_c(payload, ',');
        json_string(payload, g_ptr_array_index(panel->ids, index));
        first = FALSE;
    }
    g_string_append_printf(payload, "],\"errorsOnly\":%s,\"fromDay\":",
                            gtk_check_button_get_active(panel->errors) ? "true" : "false");
    gchar *from = day(panel->from_enabled, panel->from_calendar);
    gchar *through = day(panel->through_enabled, panel->through_calendar);
    json_string(payload, from);
    g_string_append(payload, ",\"throughDay\":");
    json_string(payload, through);
    g_string_append_c(payload, '}');
    g_free(from); g_free(through);
    return g_string_free(payload, FALSE);
}
static void apply(GtkButton *source, gpointer pointer) {
    (void)source;
    Panel *panel = pointer;
    gchar *payload = serialize(panel);
    jsti_window_emit(JSTI_EVENT_HISTORY_FILTERS, payload, 0);
    gtk_popover_popdown(panel->popover);
    g_free(payload);
}
static void reset(GtkButton *source, gpointer pointer) {
    (void)source;
    Panel *panel = pointer;
    jsti_window_emit(JSTI_EVENT_HISTORY_FILTERS,
        "{\"models\":[],\"errorsOnly\":false,\"fromDay\":\"\",\"throughDay\":\"\"}", 0);
    gtk_popover_popdown(panel->popover);
}
static void calendar_changed(GtkCalendar *calendar, gpointer pointer) {
    GtkMenuButton *date_button = pointer;
    GDateTime *date = gtk_calendar_get_date(calendar);
    gchar *label = g_date_time_format(date, "%x");
    gtk_menu_button_set_label(date_button, label);
    const gchar *name = g_object_get_data(G_OBJECT(date_button), "history-date-label");
    gchar *accessible = g_strdup_printf("%s date: %s", name, label);
    gtk_accessible_update_property(GTK_ACCESSIBLE(date_button), GTK_ACCESSIBLE_PROPERTY_LABEL, accessible, -1);
    g_free(accessible);
    g_free(label); g_date_time_unref(date);
}
static void date_enabled(GtkCheckButton *check, gpointer pointer) {
    gtk_widget_set_sensitive(GTK_WIDGET(pointer), gtk_check_button_get_active(check));
}
static void closed(GtkPopover *popover, gpointer pointer) {
    GtkMenuButton *menu = pointer;
    if (gtk_menu_button_get_popover(menu) == popover) gtk_menu_button_set_popover(menu, NULL);
}
static GtkWidget *date_row(const gchar *label, const gchar *selected,
                           GtkCheckButton **enabled, GtkCalendar **calendar) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    *enabled = GTK_CHECK_BUTTON(gtk_check_button_new_with_label(label));
    gtk_widget_set_hexpand(GTK_WIDGET(*enabled), TRUE);
    GtkWidget *date_button = gtk_menu_button_new();
    g_object_set_data_full(G_OBJECT(date_button), "history-date-label", g_strdup(label), g_free);
    *calendar = GTK_CALENDAR(gtk_calendar_new());
    if (selected && *selected) {
        gchar *iso = g_strconcat(selected, "T12:00:00", NULL);
        GTimeZone *zone = g_time_zone_new_local();
        GDateTime *date = g_date_time_new_from_iso8601(iso, zone);
        if (date) { gtk_calendar_select_day(*calendar, date); g_date_time_unref(date); }
        g_time_zone_unref(zone); g_free(iso);
    }
    GtkWidget *popover = gtk_popover_new();
    gtk_popover_set_child(GTK_POPOVER(popover), GTK_WIDGET(*calendar));
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(date_button), popover);
    calendar_changed(*calendar, date_button);
    g_signal_connect(*calendar, "day-selected", G_CALLBACK(calendar_changed), date_button);
    g_signal_connect(*enabled, "toggled", G_CALLBACK(date_enabled), date_button);
    gtk_check_button_set_active(*enabled, selected && *selected);
    gtk_widget_set_sensitive(date_button, selected && *selected);
    gtk_box_append(GTK_BOX(row), GTK_WIDGET(*enabled));
    gtk_box_append(GTK_BOX(row), date_button);
    return row;
}
static void create_popup(GtkMenuButton *menu, gpointer data) {
    (void)data;
    Panel *panel = g_new0(Panel, 1);
    panel->checks = g_ptr_array_new();
    panel->ids = g_ptr_array_new_with_free_func(g_free);
    panel->popover = GTK_POPOVER(gtk_popover_new());
    g_signal_connect(panel->popover, "closed", G_CALLBACK(closed), menu);
    g_object_set_data_full(G_OBJECT(panel->popover), "history-filter-panel", panel, panel_free);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_size_request(box, 320, -1);
    gtk_widget_set_margin_top(box, 12); gtk_widget_set_margin_bottom(box, 12);
    gtk_widget_set_margin_start(box, 12); gtk_widget_set_margin_end(box, 12);
    GtkWidget *heading = gtk_label_new("Filter History");
    gtk_label_set_xalign(GTK_LABEL(heading), 0);
    gtk_widget_add_css_class(heading, "heading");
    gtk_box_append(GTK_BOX(box), heading);
    GtkWidget *label = gtk_label_new("Models (none selected means all)");
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_box_append(GTK_BOX(box), label);
    GtkWidget *models = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    for (guint index = 0; configuration && index < configuration->models->len; ++index) {
        Model *model = g_ptr_array_index(configuration->models, index);
        GtkCheckButton *check = GTK_CHECK_BUTTON(gtk_check_button_new());
        GtkWidget *text = gtk_label_new(model->name);
        gtk_label_set_wrap(GTK_LABEL(text), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(text), PANGO_WRAP_WORD_CHAR);
        gtk_label_set_max_width_chars(GTK_LABEL(text), 36);
        gtk_label_set_xalign(GTK_LABEL(text), 0);
        gtk_check_button_set_child(check, text);
        gtk_accessible_update_property(GTK_ACCESSIBLE(check), GTK_ACCESSIBLE_PROPERTY_LABEL, model->name, -1);
        gtk_widget_set_tooltip_text(GTK_WIDGET(check), model->name);
        gtk_check_button_set_active(check, model->selected);
        gtk_box_append(GTK_BOX(models), GTK_WIDGET(check));
        g_ptr_array_add(panel->checks, check);
        g_ptr_array_add(panel->ids, g_strdup(model->id));
    }
    if (!panel->checks->len) gtk_box_append(GTK_BOX(models), gtk_label_new("No saved models yet."));
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 64);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroll), 160);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroll), TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), models);
    gtk_box_append(GTK_BOX(box), scroll);
    panel->errors = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Only recordings with errors"));
    gtk_check_button_set_active(panel->errors, configuration && configuration->errors);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(panel->errors));
    gtk_box_append(GTK_BOX(box), date_row("From", configuration ? configuration->from : "",
                                         &panel->from_enabled, &panel->from_calendar));
    gtk_box_append(GTK_BOX(box), date_row("Through", configuration ? configuration->through : "",
                                         &panel->through_enabled, &panel->through_calendar));
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *reset_button = gtk_button_new_with_label("Reset filters");
    GtkWidget *apply_button = gtk_button_new_with_label("Apply filters");
    gtk_widget_set_hexpand(reset_button, TRUE); gtk_widget_set_hexpand(apply_button, TRUE);
    gtk_widget_add_css_class(apply_button, "suggested-action");
    g_signal_connect(reset_button, "clicked", G_CALLBACK(reset), panel);
    g_signal_connect(apply_button, "clicked", G_CALLBACK(apply), panel);
    gtk_box_append(GTK_BOX(actions), reset_button); gtk_box_append(GTK_BOX(actions), apply_button);
    gtk_box_append(GTK_BOX(box), actions);
    gtk_popover_set_child(panel->popover, box);
    gtk_menu_button_set_popover(menu, GTK_WIDGET(panel->popover));
}
static void update_label(void) {
    if (!button || !configuration) return;
    guint count = configuration->errors + (configuration->from[0] != '\0') + (configuration->through[0] != '\0');
    for (guint index = 0; index < configuration->models->len; ++index) {
        count += ((Model *)g_ptr_array_index(configuration->models, index))->selected;
    }
    gchar *label = count ? g_strdup_printf("Filters (%u)", count) : g_strdup("Filters");
    gtk_menu_button_set_label(button, label);
    g_free(label);
    GtkPopover *popover = gtk_menu_button_get_popover(button);
    if (popover && !gtk_widget_get_visible(GTK_WIDGET(popover))) gtk_menu_button_set_popover(button, NULL);
}
gboolean jsti_history_filters_active(void) {
    if (!configuration) return FALSE;
    if (configuration->errors || configuration->from[0] || configuration->through[0]) return TRUE;
    for (guint index = 0; index < configuration->models->len; ++index) {
        if (((Model *)g_ptr_array_index(configuration->models, index))->selected) return TRUE;
    }
    return FALSE;
}

static void replace(gpointer pointer) {
    Configuration *incoming = pointer;
    Configuration *next = g_new0(Configuration, 1);
    next->models = g_ptr_array_ref(incoming->models);
    next->errors = incoming->errors;
    next->from = g_strdup(incoming->from); next->through = g_strdup(incoming->through);
    configuration_free(configuration); configuration = next;
    update_label();
}
static void button_finalized(gpointer data, GObject *object) {
    (void)data; (void)object;
    configuration_free(configuration);
    configuration = NULL;
}
GtkWidget *jsti_history_filters_button_new(void) {
    button = GTK_MENU_BUTTON(gtk_menu_button_new());
    g_object_add_weak_pointer(G_OBJECT(button), (gpointer *)&button);
    g_object_weak_ref(G_OBJECT(button), button_finalized, NULL);
    gtk_menu_button_set_label(button, "Filters");
    gtk_menu_button_set_create_popup_func(button, create_popup, NULL, NULL);
    update_label();
    return GTK_WIDGET(button);
}
int32_t jsti_window_set_history_filters(
    const JSTIHistoryFilterModel *models, size_t count, int32_t errors, const char *from, const char *through
) {
    if (count && !models) return -1;
    Configuration *next = g_new0(Configuration, 1);
    next->models = g_ptr_array_new_with_free_func(model_free);
    next->errors = errors != 0; next->from = g_strdup(from ? from : ""); next->through = g_strdup(through ? through : "");
    for (size_t index = 0; index < count; ++index) {
        if (!models[index].id || !models[index].name) { configuration_free(next); return -1; }
        Model *model = g_new0(Model, 1);
        model->id = g_strdup(models[index].id); model->name = g_strdup(models[index].name);
        model->selected = models[index].selected != 0;
        g_ptr_array_add(next->models, model);
    }
    return jsti_window_post(replace, next, configuration_free);
}

int32_t jsti_history_filters_self_test(char *error, size_t capacity) {
    if (!button) {
        jsti_set_error(error, capacity, "History filter button is missing.");
        return -1;
    }
    Configuration *original = configuration;
    Configuration *test = g_new0(Configuration, 1);
    test->models = g_ptr_array_new_with_free_func(model_free);
    test->from = g_strdup("2026-03-08"); test->through = g_strdup("2026-03-08"); test->errors = TRUE;
    Model *model = g_new0(Model, 1);
    model->id = g_strdup("model/\"quoted\"\n");
    model->name = g_strdup("An imported transcription model with a long descriptive name and vocabulary context");
    model->selected = TRUE;
    g_ptr_array_add(test->models, model);
    configuration = test;
    create_popup(button, NULL);
    GtkPopover *popover = gtk_menu_button_get_popover(button);
    Panel *panel = g_object_get_data(G_OBJECT(popover), "history-filter-panel");
    gchar *payload = serialize(panel);
    GtkLabel *text = GTK_LABEL(gtk_check_button_get_child(g_ptr_array_index(panel->checks, 0)));
    gboolean passed = panel->checks->len == 1 && gtk_label_get_wrap(text) &&
        gtk_label_get_wrap_mode(text) == PANGO_WRAP_WORD_CHAR && gtk_label_get_max_width_chars(text) == 36 &&
        g_strcmp0(gtk_label_get_text(text), model->name) == 0 &&
        g_strcmp0(payload, "{\"models\":[\"model/\\\"quoted\\\"\\u000a\"],\"errorsOnly\":true,"
            "\"fromDay\":\"2026-03-08\",\"throughDay\":\"2026-03-08\"}") == 0;
    gtk_check_button_set_active(panel->from_enabled, FALSE);
    gtk_check_button_set_active(panel->through_enabled, FALSE);
    gchar *from = day(panel->from_enabled, panel->from_calendar);
    gchar *through = day(panel->through_enabled, panel->through_calendar);
    passed = passed && from[0] == '\0' && through[0] == '\0';
    g_free(from); g_free(through); g_free(payload);
    gtk_menu_button_set_popover(button, NULL);
    configuration_free(test); configuration = original;
    update_label();
    if (!passed) jsti_set_error(error, capacity, "History filter controls lost model identities, dates or escaping.");
    return passed ? 0 : -1;
}
