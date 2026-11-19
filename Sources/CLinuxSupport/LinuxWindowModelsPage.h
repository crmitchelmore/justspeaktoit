/* The model and microphone pickers, as the rest of the window sees them:
 * functions only. Their state is private to LinuxWindowModels.c
 * (LinuxWindowModelsState.h). GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_MODELS_PAGE_H
#define JSTI_LINUX_WINDOW_MODELS_PAGE_H

#include "LinuxWindowInternal.h"

#pragma GCC visibility push(hidden)
/* Transcription > Model, and General > Microphone. */
GtkWidget *models_group(void);
GtkWidget *microphone_group(void);
void models_refresh_actions(gboolean idle);
/* The selected rows' display names, or NULL. */
const char *models_model_name(void);
const char *models_microphone_name(void);
/* Window close: the catalogue goes with the window. */
void models_close(void);
#pragma GCC visibility pop

#endif
