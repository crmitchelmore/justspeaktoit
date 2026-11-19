#ifndef JSTI_OPENROUTER_BROWSER_H
#define JSTI_OPENROUTER_BROWSER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* The Browse OpenRouter models… dialog (#1618). The host owns the catalogue,
   filtering and copy; the window only renders a page and selects `slot`. */
enum { JSTI_OPENROUTER_BROWSER_CLEANUP = 0, JSTI_OPENROUTER_BROWSER_TRANSCRIPTION = 1 };
typedef struct JSTIOpenRouterBrowserRow {
    const char *title;
    const char *subtitle;
    const char *details;
    /* "" when OpenRouter has no page for the model. */
    const char *url;
    /* Stable UI automation handle for the row. */
    const char *identifier;
    /* Cleanup: the post-processing list index. Transcription: the global model slot. */
    int32_t slot;
    int32_t selected;
} JSTIOpenRouterBrowserRow;
typedef struct JSTIOpenRouterBrowserPage {
    const char *title;
    const char *intro;
    const char *action;
    const char *selected_action;
    const char *search_placeholder;
    const char *all_providers;
    const char *zero_prices;
    const char *link_title;
    const char *status;
    const char *const *providers;
    size_t provider_count;
    const JSTIOpenRouterBrowserRow *rows;
    size_t row_count;
} JSTIOpenRouterBrowserPage;
/* Strings are borrowed for the duration of the call; copy what you keep. */
typedef void (*JSTIOpenRouterBrowserReceive)(const JSTIOpenRouterBrowserPage *page, void *context);
/* Filters the purpose's catalogue synchronously and calls `receive` once.
   `provider` "" means every provider; `selected_slot` -1 means none. Returns 0,
   or -1 (without calling `receive`) when the purpose has no catalogue. */
typedef int32_t (*JSTIOpenRouterBrowserQuery)(
    int32_t purpose, const char *query, const char *provider, int32_t zero_prices_only, int32_t selected_slot,
    JSTIOpenRouterBrowserReceive receive, void *context);
int32_t jsti_window_set_openrouter_browser_source(JSTIOpenRouterBrowserQuery query);
#ifdef __cplusplus
}
#endif
#endif
