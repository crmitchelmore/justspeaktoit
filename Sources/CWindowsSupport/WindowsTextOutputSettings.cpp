#include "WindowsTextOutputSettingsInternal.hpp"
#include <mutex>

// The host's Text output configuration: the output method, insertion mode and
// clipboard restoration used by recordings started after Apply, the app-switch
// policy choices and the borrowed Apply callback. It is private to this file,
// behind its mutex; the dialog copies it when it opens.

using namespace jsti::textOutputSettings;

namespace {
std::mutex configurationMutex;
Configuration configuration;
thread_local int applyingAppSwitchSelection = -1;

bool valid(int method, int insertion, int restore) {
    return method >= JSTI_TEXT_OUTPUT_SMART && method <= JSTI_TEXT_OUTPUT_CLIPBOARD_ONLY &&
        (insertion == JSTI_TEXT_OUTPUT_AT_CURSOR || insertion == JSTI_TEXT_OUTPUT_REPLACE_FIELD) &&
        (restore == 0 || restore == 1);
}
} // namespace

namespace jsti::textOutputSettings {

Configuration configurationSnapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}

Configuration exchangeConfiguration(Configuration next) {
    std::lock_guard<std::mutex> lock(configurationMutex);
    std::swap(configuration, next);
    return next;
}

void deliverApply(const Configuration &config, const Choice &choice, int appSwitchSelection) {
    if (!config.callback) return;
    applyingAppSwitchSelection = appSwitchSelection;
    config.callback(choice.method, choice.insertion, choice.restore ? 1 : 0, config.context);
    applyingAppSwitchSelection = -1;
}

} // namespace jsti::textOutputSettings

bool jsti_text_output_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback != nullptr;
}

int jsti_window_set_text_output(int method, int insertion, int restoreClipboard,
                                JSTITextOutputSettingsCallback callback, void *context) {
    if (!callback || !valid(method, insertion, restoreClipboard)) return -1;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration.choice = {method, insertion, restoreClipboard != 0};
        configuration.callback = callback;
        configuration.context = context;
    }
    // Configuration is valid before the main window exists; afterwards this
    // refreshes the button's availability.
    jsti_window_update(nullptr, nullptr, -1);
    return 0;
}

int jsti_window_text_output(int *method, int *insertion, int *restoreClipboard) {
    if (!method || !insertion || !restoreClipboard) return -1;
    std::lock_guard<std::mutex> lock(configurationMutex);
    if (!configuration.callback) return -1;
    *method = configuration.choice.method;
    *insertion = configuration.choice.insertion;
    *restoreClipboard = configuration.choice.restore ? 1 : 0;
    return 0;
}

int jsti_window_set_app_switch(const char *title, const char *labels, int selection, const char *help) {
    std::wstring wideTitle, wideLabels, wideHelp;
    if (!jsti::wide(title, wideTitle) || !jsti::wide(labels, wideLabels) || !jsti::wide(help, wideHelp)) return -1;
    std::vector<std::wstring> choices;
    size_t start = 0;
    while (start < wideLabels.size()) {
        const size_t end = wideLabels.find(L'\n', start);
        auto value = wideLabels.substr(start, end == std::wstring::npos ? end : end - start);
        if (value.empty()) return -1;
        choices.push_back(std::move(value));
        if (end == std::wstring::npos) break;
        start = end + 1;
    }
    if (wideTitle.empty() || choices.empty() || selection < 0 || static_cast<size_t>(selection) >= choices.size()) return -1;
    std::lock_guard<std::mutex> lock(configurationMutex);
    configuration.appSwitchTitle = std::move(wideTitle);
    configuration.appSwitchHelp = std::move(wideHelp);
    configuration.appSwitchLabels = std::move(choices);
    configuration.appSwitchSelection = selection;
    return 0;
}

int jsti_window_app_switch_selection(void) {
    if (applyingAppSwitchSelection >= 0) return applyingAppSwitchSelection;
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.appSwitchSelection;
}

void jsti_window_clear_text_output(void) {
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = Configuration(); }
    jsti_window_update(nullptr, nullptr, -1);
}
