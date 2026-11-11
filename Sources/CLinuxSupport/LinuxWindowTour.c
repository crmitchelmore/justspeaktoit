/* Window snapshots and the screenshot tour. */
#include "LinuxWindowInternal.h"

/* ------------------------------------------------------ screenshot tour */

/* Renders `widget` at its allocated size into a PNG, over the window's
 * background colour when `opaque`. */
int32_t jsti_widget_save_snapshot(GtkWidget *widget, const char *path, gboolean opaque) {
    int width = gtk_widget_get_width(widget), height = gtk_widget_get_height(widget);
    if (width <= 0 || height <= 0) return -1;
    GtkSnapshot *snapshot = gtk_snapshot_new();
    if (opaque) {
        gboolean dark = adw_style_manager_get_dark(adw_style_manager_get_default());
        GdkRGBA background = dark ? (GdkRGBA){ 0.141, 0.141, 0.141, 1 } : (GdkRGBA){ 0.98, 0.98, 0.98, 1 };
        gtk_snapshot_append_color(snapshot, &background, &GRAPHENE_RECT_INIT(0, 0, (float)width, (float)height));
    }
    GdkPaintable *paintable = gtk_widget_paintable_new(widget);
    gdk_paintable_snapshot(paintable, snapshot, width, height);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    int32_t result = -1;
    if (node != NULL) {
        GskRenderer *renderer = gtk_native_get_renderer(gtk_widget_get_native(widget));
        GdkTexture *texture = gsk_renderer_render_texture(
            renderer, node, &GRAPHENE_RECT_INIT(0, 0, (float)width, (float)height));
        if (texture != NULL && gdk_texture_save_to_png(texture, path)) result = 0;
        if (texture != NULL) g_object_unref(texture);
        gsk_render_node_unref(node);
    }
    g_object_unref(paintable);
    return result;
}

typedef struct Tour {
    gchar *directory;
    gint32 step;
    TextOutput output;
} Tour;
enum { TOUR_PORTAL_OUTPUT = JSTI_PAGE_COUNT, TOUR_DARK_DASHBOARD, TOUR_DARK_HISTORY, TOUR_RECORDING, TOUR_HUD_RECORDING,
       TOUR_HUD_COMPLETED, TOUR_HISTORY_FILTERS, TOUR_DARK_HISTORY_FILTERS, TOUR_DARK_GENERAL, TOUR_EXPANDED_RECORDING,
       TOUR_COMPACT_RECORDING, TOUR_COMPACT_COMPLETED, TOUR_VOICE_SOURCES, TOUR_VOICE_CONTROLS, TOUR_VOICE_USAGE,
       TOUR_VOICE_DISCOVERY, TOUR_DONE };

static gboolean tour_capture(gpointer data);

static void tour_show(Tour *tour) {
    if (tour->step < JSTI_PAGE_COUNT) {
        show_page(tour->step);
    } else if (tour->step == TOUR_PORTAL_OUTPUT) {
        TextOutput portal = { .method = 0, .restore = TRUE, .can_restore = FALSE };
        text_output_apply(&portal);
        show_page(JSTI_PAGE_GENERAL);
    } else if (tour->step == TOUR_DARK_DASHBOARD) {
        text_output_apply(&tour->output);
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_FORCE_DARK);
        show_page(JSTI_PAGE_DASHBOARD);
    } else if (tour->step == TOUR_DARK_HISTORY) {
        show_page(JSTI_PAGE_HISTORY);
    } else if (tour->step == TOUR_DARK_GENERAL) {
        Update idle = { .state = JSTI_STATE_IDLE };
        update_apply(&idle);
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_FORCE_DARK);
        show_page(JSTI_PAGE_GENERAL);
    } else if (tour->step == TOUR_HISTORY_FILTERS || tour->step == TOUR_DARK_HISTORY_FILTERS) {
        Update idle = { .state = JSTI_STATE_IDLE };
        update_apply(&idle);
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(),
            tour->step == TOUR_HISTORY_FILTERS ? ADW_COLOR_SCHEME_FORCE_LIGHT : ADW_COLOR_SCHEME_FORCE_DARK);
        show_page(JSTI_PAGE_HISTORY);
        gtk_menu_button_popup(GTK_MENU_BUTTON(ui.history_page.history_filters));
    } else if (tour->step == TOUR_HUD_RECORDING) {
        jsti_hud_show(1, "Recording", "Capturing audio",
                      "Could we move the catch-up to Friday? That gives us a little more time");
    } else if (tour->step == TOUR_HUD_COMPLETED) {
        jsti_hud_show(5, "Completed", "Saved. Pasted into the original window.", "");
    } else if (tour->step == TOUR_EXPANDED_RECORDING) {
        jsti_hud_show_layout(1, "Recording", "Capturing audio",
                              "Could we move the catch-up to Friday? That gives us a little more time to finish "
                              "the proposal and review the notes together before sending them to the team.", 0, FALSE, TRUE);
    } else if (tour->step == TOUR_COMPACT_RECORDING) {
        jsti_hud_show_presentation(1, "Recording", "Capturing audio",
                                    "Could we move the catch-up to Friday? That gives us a little more time", 0, TRUE);
    } else if (tour->step == TOUR_COMPACT_COMPLETED) {
        jsti_hud_show_presentation(5, "Completed", "Saved. Pasted into the original window.", "", 2400, TRUE);
    } else if (tour->step == TOUR_VOICE_SOURCES) {
        jsti_hud_destroy();
        jsti_voice_sources_show_fixture(ui.window);
    } else if (tour->step == TOUR_VOICE_CONTROLS) {
        jsti_voice_sources_close();
        jsti_voice_controls_show_fixture(ui.window);
    } else if (tour->step == TOUR_VOICE_USAGE) {
        jsti_voice_usage_show_fixture(ui.window);
    } else if (tour->step == TOUR_VOICE_DISCOVERY) {
        jsti_voice_discovery_show_fixture(ui.window);
    } else {
        /* Late, because it replaces the displayed transcript. */
        Update recording = { .transcript = (gchar *)"Could we move the catch-up to Friday? That gives us a little",
                             .has_transcript = TRUE, .state = JSTI_STATE_RECORDING,
                             .status = (gchar *)"Recording… Press Ctrl+Alt+Space again to stop." };
        update_apply(&recording);
        show_page(JSTI_PAGE_DASHBOARD);
    }
    g_timeout_add(700, tour_capture, tour);
}

static const char *tour_name(gint32 step) {
    switch (step) {
    case TOUR_PORTAL_OUTPUT: return "general-portal-output";
    case TOUR_RECORDING: return "dashboard-recording";
    case TOUR_HUD_RECORDING: return "hud-recording";
    case TOUR_HUD_COMPLETED: return "hud-completed";
    case TOUR_EXPANDED_RECORDING: return "hud-expanded-recording";
    case TOUR_COMPACT_RECORDING: return "hud-compact-recording";
    case TOUR_COMPACT_COMPLETED: return "hud-compact-completed";
    case TOUR_DARK_DASHBOARD: return "dashboard-dark";
    case TOUR_DARK_HISTORY: return "history-dark";
    case TOUR_HISTORY_FILTERS: return "history-filters";
    case TOUR_DARK_HISTORY_FILTERS: return "history-filters-dark";
    case TOUR_VOICE_SOURCES: return "voice-sources";
    case TOUR_VOICE_CONTROLS: return "voice-controls";
    case TOUR_VOICE_USAGE: return "voice-usage";
    case TOUR_DARK_GENERAL: return "general-dark";
    case TOUR_VOICE_DISCOVERY: return "voice-discovery";
    default: return page_info[step].name;
    }
}

static gboolean tour_capture(gpointer data) {
    Tour *tour = data;
    if (ui.window == NULL) {
        g_free(tour->directory);
        g_free(tour);
        return G_SOURCE_REMOVE;
    }
    gchar *file = g_strdup_printf("%02d-%s.png", tour->step + 1, tour_name(tour->step));
    gchar *path = g_build_filename(tour->directory, file, NULL);
    char message[256] = { 0 };
    if (tour->step == TOUR_HISTORY_FILTERS || tour->step == TOUR_DARK_HISTORY_FILTERS) {
        GtkPopover *popover = gtk_menu_button_get_popover(GTK_MENU_BUTTON(ui.history_page.history_filters));
        if (!popover || jsti_widget_save_snapshot(GTK_WIDGET(popover), path, TRUE) != 0) {
            g_printerr("The History filter editor %s could not be saved.\n", file);
        }
        gtk_menu_button_set_popover(GTK_MENU_BUTTON(ui.history_page.history_filters), NULL);
        g_free(path); g_free(file);
        tour->step++;
        if (tour->step < TOUR_DONE) tour_show(tour);
        else {
            g_free(tour->directory); g_free(tour);
            gtk_window_close(ui.window);
        }
        return G_SOURCE_REMOVE;
    }
    if (tour->step == TOUR_VOICE_CONTROLS) {
        if (jsti_voice_controls_save_snapshot(path) != 0) g_printerr("The Voice controls snapshot failed.\n");
        g_free(path); g_free(file);
        tour->step++; tour_show(tour);
        return G_SOURCE_REMOVE;
    }
    if (tour->step == TOUR_VOICE_USAGE) {
        if (jsti_voice_usage_save_snapshot(path) != 0) g_printerr("The Voice usage snapshot failed.\n");
        g_free(path); g_free(file);
        tour->step++; tour_show(tour);
        return G_SOURCE_REMOVE;
    }
    if (tour->step == TOUR_VOICE_DISCOVERY) {
        if (jsti_voice_discovery_save_snapshot(path) != 0) g_printerr("The account voice snapshot failed.\n");
        g_free(path); g_free(file);
        jsti_comparison_screenshot_tour(ui.window, tour->directory);
        g_free(tour->directory); g_free(tour);
        return G_SOURCE_REMOVE;
    }
    if (tour->step == TOUR_VOICE_SOURCES) {
        if (jsti_voice_sources_save_snapshot(path) != 0) g_printerr("The Voice Output editor snapshot failed.\n");
        g_free(path); g_free(file);
        tour->step++;
        if (tour->step < TOUR_DONE) {
            tour_show(tour);
        } else {
            jsti_comparison_screenshot_tour(ui.window, tour->directory);
            g_free(tour->directory);
            g_free(tour);
        }
        return G_SOURCE_REMOVE;
    }
    if ((tour->step >= TOUR_HUD_RECORDING && tour->step <= TOUR_HUD_COMPLETED) ||
        (tour->step >= TOUR_EXPANDED_RECORDING && tour->step <= TOUR_COMPACT_COMPLETED)) {
        /* The HUD is its own window; X11 only. */
        GtkWidget *card = jsti_hud_card();
        if (card != NULL && jsti_widget_save_snapshot(card, path, TRUE) != 0) g_printerr("The HUD %s could not be saved.\n", file);
        g_free(path);
        g_free(file);
        tour->step++;
        if (tour->step < TOUR_DONE) {
            tour_show(tour);
        } else {
            jsti_comparison_screenshot_tour(ui.window, tour->directory);
            g_free(tour->directory);
            g_free(tour);
        }
        return G_SOURCE_REMOVE;
    }
    if (jsti_window_save_snapshot(path, message, sizeof message) != 0) g_printerr("%s\n", message);
    g_free(path);
    g_free(file);
    /* The whole page too, below the fold, on the window's background. */
    GtkWidget *scroller = gtk_stack_get_visible_child(ui.pages);
    GtkWidget *viewport = GTK_IS_SCROLLED_WINDOW(scroller) ? gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(scroller))
                                                           : NULL;
    GtkWidget *column = viewport != NULL ? gtk_widget_get_first_child(viewport) : NULL;
    if (column != NULL) {
        file = g_strdup_printf("%02d-%s-full.png", tour->step + 1, tour_name(tour->step));
        path = g_build_filename(tour->directory, file, NULL);
        if (jsti_widget_save_snapshot(column, path, TRUE) != 0) g_printerr("The full page %s could not be saved.\n", file);
        g_free(path);
        g_free(file);
    }
    tour->step++;
    if (tour->step < TOUR_DONE) {
        tour_show(tour);
    } else {
        jsti_comparison_screenshot_tour(ui.window, tour->directory);
        g_free(tour->directory);
        g_free(tour);
    }
    return G_SOURCE_REMOVE;
}

static void tour_start(gpointer data) {
    Tour *tour = data;
    const JSTIHistoryFilterModel models[] = {
        {"model/sample", "Sample transcription model", 0},
        {"model/long", "An imported transcription model with a long descriptive name and vocabulary context", 0}
    };
    if (jsti_window_set_history_filters(models, 2, 0, "", "") != 0) {
        g_printerr("Could not prepare the sample History filter editor.\n");
        g_free(tour->directory); g_free(tour);
        gtk_window_close(ui.window);
        return;
    }
    tour->output = (TextOutput){
        .method = (gint32)adw_combo_row_get_selected(ui.output.output_row),
        .restore = adw_switch_row_get_active(ui.output.restore_row),
        .can_restore = ui.output.can_restore_clipboard
    };
    tour_show(tour);
}

int32_t jsti_window_screenshot_tour(const char *directory, char *error, size_t capacity) {
    if (directory == NULL || g_mkdir_with_parents(directory, 0700) != 0) {
        jsti_set_error(error, capacity, "The screenshot folder could not be created.");
        return -1;
    }
    Tour *tour = g_new0(Tour, 1);
    tour->directory = g_strdup(directory);
    /* The tour owns itself once started; post() frees nothing. */
    return post(tour_start, tour, NULL);
}

/* Window smoke-test failures share one prefix; the self-test target reports through it too. */
int32_t fail(char *error, size_t capacity, const char *message) {
    jsti_set_error(error, capacity, "Window self-test: %s", message);
    return -1;
}

/* Renders the window to a PNG for visual review in smoke tests. */
int32_t jsti_window_save_snapshot(const char *path, char *error, size_t capacity) {
    if (ui.window == NULL) return fail(error, capacity, "no window to capture");
    /* A root's own paintable is empty; capture its content instead. */
    GtkWidget *widget = adw_application_window_get_content(ADW_APPLICATION_WINDOW(ui.window));
    int width = gtk_widget_get_width(widget), height = gtk_widget_get_height(widget);
    GdkPaintable *paintable = gtk_widget_paintable_new(widget);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gdk_paintable_snapshot(paintable, snapshot, width, height);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    int32_t result = -1;
    if (node != NULL) {
        GskRenderer *renderer = gtk_native_get_renderer(GTK_NATIVE(ui.window));
        GdkTexture *texture = gsk_renderer_render_texture(
            renderer, node, &GRAPHENE_RECT_INIT(0, 0, (float)width, (float)height));
        if (texture != NULL && gdk_texture_save_to_png(texture, path)) result = 0;
        if (texture != NULL) g_object_unref(texture);
        gsk_render_node_unref(node);
    }
    g_object_unref(paintable);
    if (result != 0) jsti_set_error(error, capacity, "The window snapshot could not be saved (%dx%d, node %s).", width, height, node != NULL ? "rendered" : "empty");
    return result;
}
