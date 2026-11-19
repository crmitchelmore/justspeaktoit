#ifndef JSTI_LINUX_WINDOW_MODELS_H
#define JSTI_LINUX_WINDOW_MODELS_H
/* Model, History, insights and profile rows, and the window pages. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JSTIModelRow {
    const char *id;
    const char *name;
    int32_t is_live;
    /* Position in the picker, or -1 when hidden. */
    int32_t display_order;
} JSTIModelRow;

/* One History card, worded by the shared DesktopHistoryRowSummary. Empty
 * strings hide their badge. tone: 0 transcribed, 1 failed, 2 not yet
 * transcribed. */
typedef struct JSTIHistoryRow {
    const char *id;
    const char *created;
    const char *audio_length;
    const char *cost;
    const char *preview;
    const char *models;
    const char *context;
    int32_t tone;
} JSTIHistoryRow;

typedef struct JSTIHistoryFilterModel {
    const char *id;
    const char *name;
    int32_t selected;
} JSTIHistoryFilterModel;
int32_t jsti_window_set_history_filters(const JSTIHistoryFilterModel *models, size_t count,
                                        int32_t errors_only, const char *from_day, const char *through_day);

/* Preformatted History totals, as the Mac dashboard shows them. */
typedef struct JSTIInsights {
    const char *sessions;
    const char *errors;
    const char *recording_time;
    const char *average_length;
    const char *spend;
} JSTIInsights;

/* The window's pages, in sidebar order. */
enum {
    JSTI_PAGE_DASHBOARD = 0,
    JSTI_PAGE_HISTORY,
    JSTI_PAGE_VOICE_OUTPUT,
    JSTI_PAGE_GENERAL,
    JSTI_PAGE_TRANSCRIPTION,
    JSTI_PAGE_POST_PROCESSING,
    JSTI_PAGE_CORRECTIONS,
    JSTI_PAGE_PRONUNCIATION,
    JSTI_PAGE_PROFILES,
    JSTI_PAGE_KEYBOARD,
    JSTI_PAGE_CLOUD_SYNC,
    JSTI_PAGE_ABOUT,
    JSTI_PAGE_COUNT
};

/* Owned, ordered main-thread update. replace=0 only reports an error and keeps
 * unsaved form contents; replace=1 carries the full H/T/P/L/R profile projection.
 * Every string is copied before returning; queued strings are freed on close. */
int32_t jsti_profiles_set(const char *wire, int32_t replacing);

enum { JSTI_WINDOW_SMOKE_TEST = 1 };

#ifdef __cplusplus
}
#endif
#endif
