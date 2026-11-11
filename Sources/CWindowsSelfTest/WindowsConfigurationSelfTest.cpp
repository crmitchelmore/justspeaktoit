// The Dictation preferences dialog's checks, run by the window self-test.
#include "../CWindowsSupport/WindowsConfigurationInternal.hpp"
#include "../CWindowsSupport/WindowsWindowChrome.hpp"
#include <algorithm>
#include <cstring>

bool jsti_configuration_field_available(size_t index);

using namespace jsti::configuration;
using jsti::chrome::scale;

static bool configurationTitleSelfTest(HWND owner, std::string &error) {
    Dialog fixture;
    fixture.config.fields = {{L"Soniox voice language", L"en_GB", L"Voice Output", false}};
    fixture.group = L"Voice Output";
    HWND window = createDialog(owner, fixture);
    if (!window) { error = "Could not create the Voice language label fixture."; return false; }
    Configuration previous = exchangeConfiguration(fixture.config);
    HWND previousWindow = exchangeActiveEditor(window);
    SetDlgItemTextW(window, fieldBase, L"fr_FR");
    const bool queued = jsti_window_set_configuration_field_title(0, "Gemini voice language") == 0;
    SendMessageW(window, refreshTitleMessage, 0, 0);
    const bool preserved = text(window, labelBase) == L"Gemini voice language" &&
        text(window, fieldBase) == L"fr_FR";
    const bool refused = jsti_window_set_configuration_field_title(32, "Invalid") < 0 &&
        jsti_window_set_configuration_field_title(0, nullptr) < 0 &&
        jsti_window_set_configuration_field_title(0, "") < 0 &&
        jsti_window_set_configuration_field_enabled(32, 1) < 0 &&
        jsti_window_set_configuration_field_enabled(0, 2) < 0;
    bool availabilityPreserved = jsti_window_set_configuration_field_enabled(0, 0) == 0;
    SendMessageW(window, refreshTitleMessage, 0, 0);
    availabilityPreserved = availabilityPreserved && !IsWindowEnabled(GetDlgItem(window, fieldBase)) &&
        text(window, fieldBase) == L"fr_FR" && jsti_window_set_configuration_field_enabled(0, 1) == 0;
    SendMessageW(window, refreshTitleMessage, 0, 0);
    availabilityPreserved = availabilityPreserved && IsWindowEnabled(GetDlgItem(window, fieldBase)) &&
        text(window, fieldBase) == L"fr_FR";
    struct RevisionTest { int renders = 0, applies = 0; } revisionTest;
    const auto revisionCallback = [](int action, const char *const *values, size_t count,
        void *context, char *, size_t) -> int {
        auto &test = *static_cast<RevisionTest *>(context);
        const std::string revision = "12345678-1234-1234-1234-123456789abc";
        if (action == 6 && count == 1 && std::string(values[0]) == revision) {
            ++test.renders; return 0;
        }
        if (action == 0 && count == 2 && std::string(values[0]) == "Effective hints" &&
            std::string(values[1]) == revision) { ++test.applies; return 0; }
        return -1;
    };
    JSTIConfigurationField revised{};
    revised.title = "AssemblyAI hints"; revised.value = "Effective hints"; revised.group = "Transcription";
    const bool revisionRendered = jsti_window_set_configuration_revision(
        &revised, 1, nullptr, 0, revisionCallback, &revisionTest, "12345678-1234-1234-1234-123456789abc") == 0 &&
        text(window, fieldBase) == L"Effective hints" && revisionTest.renders == 1;
    if (revisionRendered) SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool revisionApplied = !IsWindow(window) && revisionTest.applies == 1;
    if (IsWindow(window)) DestroyWindow(window);
    exchangeConfiguration(std::move(previous));
    exchangeActiveEditor(previousWindow);
    if (!queued || !preserved || !refused || !availabilityPreserved || !revisionRendered || !revisionApplied) {
        error = "Configuration labels, live snapshot replacement or emitted view revision failed.";
        return false;
    }
    return true;
}

static bool configurationAutoCleanSelfTest(HWND owner, std::string &error) {
    Configuration previous = hostConfiguration();
    struct Applied { int calls = 0; bool correct = false; } applied;
    const auto callback = [](int action, const char *const *values, size_t count, void *context,
                              char *, size_t) -> int {
        auto &result = *static_cast<Applied *>(context);
        ++result.calls;
        result.correct = action == 0 && count == 33 &&
            std::string(values[0]) == "preserved" && std::string(values[28]) == "instant" &&
            std::string(values[29]) == "fixture/model" && std::string(values[30]) == "250" &&
            std::string(values[31]) == "3" && std::string(values[32]) == "0";
        return result.correct ? 0 : -1;
    };
    std::vector<JSTIConfigurationField> fields(33);
    for (auto &field : fields) {
        field.title = "Existing setting"; field.value = "preserved"; field.group = "General";
    }
    fields[28].title = "Live processing speed"; fields[28].value = "livePolish";
    fields[28].choices = "instant\tInstant\nlivePolish\tAuto-Clean";
    fields[29].title = "Auto-Clean model"; fields[29].value = "captured/model";
    fields[30].title = "Auto-Clean debounce"; fields[30].value = "500";
    fields[31].title = "Auto-Clean minimum delta"; fields[31].value = "20";
    fields[32].title = "Skip ordinary cleanup"; fields[32].value = "1"; fields[32].is_boolean = 1;
    for (size_t index = 28; index < fields.size(); ++index) fields[index].group = "Transcription";
    const bool registered = jsti_window_set_configuration(
        fields.data(), fields.size(), nullptr, 0, callback, &applied) == 0;
    Dialog fixture;
    fixture.config = hostConfiguration();
    fixture.group = L"Transcription";
    HWND window = registered ? createDialog(owner, fixture) : nullptr;
    bool accepted = false;
    if (window) {
        const bool populated = IsWindow(GetDlgItem(window, fieldBase + 32)) &&
            SendDlgItemMessageW(window, fieldBase + 28, CB_GETCOUNT, 0, 0) == 2 &&
            SendDlgItemMessageW(window, fieldBase + 28, CB_GETCURSEL, 0, 0) == 1;
        SendDlgItemMessageW(window, fieldBase + 28, CB_SETCURSEL, 0, 0);
        SetDlgItemTextW(window, fieldBase + 29, L"fixture/model");
        SetDlgItemTextW(window, fieldBase + 30, L"250");
        SetDlgItemTextW(window, fieldBase + 31, L"3");
        SendDlgItemMessageW(window, fieldBase + 32, BM_SETCHECK, BST_UNCHECKED, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
        accepted = populated && !IsWindow(window) && applied.calls == 1 && applied.correct;
        if (IsWindow(window)) DestroyWindow(window);
    }
    const bool bounded = jsti_window_set_configuration(
        fields.data(), maximumConfigurationFields + 1, nullptr, 0, callback, &applied) < 0;
    exchangeConfiguration(std::move(previous));
    if (!registered || !accepted || !bounded) {
        error = "Auto-Clean preferences did not register or apply past the former 32-field limit.";
        return false;
    }
    return true;
}

static bool configurationEmptyChoiceSelfTest(HWND owner, std::string &error) {
    Configuration previous = hostConfiguration();
    struct Applied { int calls = 0; std::string expected; bool correct = false; } applied;
    const auto callback = [](int action, const char *const *values, size_t count, void *context,
                              char *, size_t) -> int {
        auto &result = *static_cast<Applied *>(context);
        ++result.calls;
        result.correct = action == 0 && count == 2 && values && values[0] && values[1] &&
            std::string(values[0]) == result.expected && std::string(values[1]) == "preserved";
        return result.correct ? 0 : -1;
    };
    JSTIConfigurationField fields[2]{};
    fields[0].title = "Destination policy"; fields[0].value = ""; fields[0].group = "General";
    fields[0].choices = "\tLegacy fixture\nretained\tExplicit fixture";
    fields[1].title = "Other setting"; fields[1].value = "preserved"; fields[1].group = "General";
    const auto registerFields = [&] {
        return jsti_window_set_configuration(fields, 2, nullptr, 0, callback, &applied);
    };
    bool okay = registerFields() == 0;
    const auto retained = [&] {
        const Configuration current = hostConfiguration();
        return current.fields.size() == 2 && current.fields[0].choices.size() == 2 &&
            current.fields[0].choices[0] == std::make_pair(std::wstring(), std::wstring(L"Legacy fixture")) &&
            current.fields[0].value.empty() && current.fields[1].value == L"preserved" &&
            current.callback == callback && current.context == &applied;
    };
    okay = okay && retained();
    const char *invalid[] = {
        "\tLegacy\n\tDuplicate empty", "\tLegacy\nretained\tFirst\nretained\tDuplicate",
        "\t", "\tLegacy\textra", "Missing separator", "\tLegacy\nretained\t", "\tLegacy\n"
    };
    for (const char *choices : invalid) {
        fields[0].choices = choices;
        okay = registerFields() == -1 && retained() && okay;
    }
    std::string bounded = "\tLegacy fixture";
    for (int index = 1; index < 32; ++index) bounded += "\nvalue" + std::to_string(index) + "\tChoice";
    fields[0].choices = bounded.c_str();
    okay = registerFields() == 0 && okay;
    bounded += "\nextra\tThirty-third choice";
    fields[0].choices = bounded.c_str();
    okay = registerFields() == -1 && okay;
    const std::string oversized(65536, 'x');
    fields[0].choices = oversized.c_str();
    okay = registerFields() == -1 && okay;
    fields[0].choices = "\tLegacy fixture\nretained\tExplicit fixture";
    okay = registerFields() == 0 && retained() && okay;
    fields[0].value = "not-listed";
    okay = registerFields() == -1 && retained() && okay;
    fields[0].value = "";
    fields[0].is_boolean = 1;
    okay = registerFields() == -1 && retained() && okay;
    fields[0].is_boolean = 0;
    fields[0].value = " retained ";
    fields[0].choices = "\tLegacy fixture\n retained \tExplicit fixture";
    okay = registerFields() == 0 && okay;
    {
        const Configuration current = hostConfiguration();
        okay = current.fields.size() == 2 && current.fields[0].choices.size() == 2 &&
            current.fields[0].value == L" retained " &&
            current.fields[0].choices[1].first == L" retained " && okay;
    }
    fields[0].value = "";
    fields[0].choices = "\tLegacy fixture\nretained\tExplicit fixture";
    okay = registerFields() == 0 && retained() && okay;
    for (int selection = 0; selection < 2; ++selection) {
        Dialog fixture;
        fixture.config = hostConfiguration();
        HWND window = okay ? createDialog(owner, fixture) : nullptr;
        if (!window) { okay = false; break; }
        const bool populated = SendDlgItemMessageW(window, fieldBase, CB_GETCOUNT, 0, 0) == 2 &&
            SendDlgItemMessageW(window, fieldBase, CB_GETCURSEL, 0, 0) == 0;
        SendDlgItemMessageW(window, fieldBase, CB_SETCURSEL, selection, 0);
        applied.expected = selection == 0 ? "" : "retained";
        const int before = applied.calls;
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
        okay = populated && !IsWindow(window) && applied.calls == before + 1 && applied.correct && okay;
        if (IsWindow(window)) DestroyWindow(window);
    }
    exchangeConfiguration(std::move(previous));
    if (!okay) error = "Optional choice registration lost an empty draft, accepted ambiguous metadata or changed Apply values.";
    return okay;
}

static bool configurationWarmApprovalSelfTest(HWND owner, std::string &error) {
    struct Applied { int calls = 0; bool approved = false; } applied;
    auto make = [&]() {
        Dialog dialog;
        dialog.group = L"Post-processing";
        dialog.config.fields = {
            {L"Connection intent", L"1", L"Post-processing", true},
            {L"Session approval", L"0", L"Post-processing", true, {}, false, 1}
        };
        dialog.config.context = &applied;
        dialog.config.callback = [](int action, const char *const *values, size_t count, void *context,
                                      char *message, size_t capacity) {
            auto &state = *static_cast<Applied *>(context);
            if (action != 0 || count != 2 || std::string(values[0]) != "1" ||
                std::string(values[1]) != (state.approved ? "1" : "0"))
                return jsti::fail("Intent was mistaken for explicit session approval.", message, capacity);
            ++state.calls;
            return 0;
        };
        return dialog;
    };
    Dialog first = make();
    HWND window = createDialog(owner, first);
    if (!window) { error = "Could not create connection approval fixture."; return false; }
    const auto checked = [&]() {
        return SendDlgItemMessageW(window, fieldBase + 1, BM_GETCHECK, 0, 0) == BST_CHECKED;
    };
    bool valid = IsWindowEnabled(GetDlgItem(window, fieldBase + 1)) && !checked();
    SendDlgItemMessageW(window, fieldBase, BM_SETCHECK, BST_UNCHECKED, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(fieldBase, BN_CLICKED), 0);
    valid = valid && !IsWindowEnabled(GetDlgItem(window, fieldBase + 1)) && !checked();
    SendDlgItemMessageW(window, fieldBase, BM_SETCHECK, BST_CHECKED, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(fieldBase, BN_CLICKED), 0);
    valid = valid && IsWindowEnabled(GetDlgItem(window, fieldBase + 1)) && !checked();
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    valid = valid && !IsWindow(window) && applied.calls == 1;
    if (IsWindow(window)) DestroyWindow(window);
    Dialog second = make();
    window = createDialog(owner, second);
    if (!window) { error = "Could not create explicit approval fixture."; return false; }
    valid = valid && !checked();
    SendDlgItemMessageW(window, fieldBase + 1, BM_SETCHECK, BST_CHECKED, 0);
    applied.approved = true;
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    valid = valid && !IsWindow(window) && applied.calls == 2;
    if (IsWindow(window)) DestroyWindow(window);
    Dialog cancelled = make();
    window = createDialog(owner, cancelled);
    if (!window) { error = "Could not create cancelled approval fixture."; return false; }
    SendDlgItemMessageW(window, fieldBase + 1, BM_SETCHECK, BST_CHECKED, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
    valid = valid && !IsWindow(window) && applied.calls == 2;
    if (IsWindow(window)) DestroyWindow(window);
    if (!valid) error = "Connection intent, explicit approval, dependency or Cancel was conflated.";
    return valid;
}

// Search reveals a field: its group is shown, it scrolls into view and takes the
// focus; a field of another group or out of range is refused.
static bool configurationRevealSelfTest(HWND owner, std::string &error) {
    Dialog fixture;
    for (int index = 0; index < 24; ++index)
        fixture.config.fields.push_back({L"Setting " + std::to_wstring(index), L"value",
            index == 2 ? L"General" : L"Transcription", false});
    fixture.group = L"Transcription";
    HWND window = createDialog(owner, fixture);
    if (!window) { error = "Could not create the configuration reveal fixture."; return false; }
    const bool lateHidden = !(GetWindowLongW(GetDlgItem(window, fieldBase + 23), GWL_STYLE) & WS_VISIBLE);
    const bool revealed = revealField(window, fixture, 23) && fixture.scrollOffset > 0 &&
        (GetWindowLongW(GetDlgItem(window, fieldBase + 23), GWL_STYLE) & WS_VISIBLE) &&
        !(GetWindowLongW(GetDlgItem(window, fieldBase), GWL_STYLE) & WS_VISIBLE);
    const bool refused = !revealField(window, fixture, 2) && !revealField(window, fixture, 24);
    DestroyWindow(window);
    Configuration previous = exchangeConfiguration(Configuration());
    const bool unconfigured = hostConfiguration().fields.empty() && !jsti_configuration_field_available(0) &&
        jsti_window_reveal_configuration_field(0) == -1;
    exchangeConfiguration(std::move(previous));
    const bool outOfRange = !jsti_configuration_field_available(maximumConfigurationFields) &&
        jsti_window_reveal_configuration_field(maximumConfigurationFields) == -1 &&
        jsti_window_reveal_configuration_field(static_cast<size_t>(-1)) == -1;
    if (!lateHidden || !revealed || !refused || !unconfigured || !outOfRange) {
        error = "Revealing a configuration field from search failed to scroll, focus or refuse.";
        return false;
    }
    return true;
}

bool jsti_configuration_self_test(HWND owner, std::string &error) {
    if (!configurationRevealSelfTest(owner, error)) return false;
    if (!configurationWarmApprovalSelfTest(owner, error)) return false;
    if (!configurationTitleSelfTest(owner, error)) return false;
    if (!configurationAutoCleanSelfTest(owner, error)) return false;
    if (!configurationEmptyChoiceSelfTest(owner, error)) return false;
    struct LearningApplied { int calls = 0; bool correct = false; } learningApplied;
    Dialog learning;
    learning.group = L"Corrections";
    learning.config.fields = {{L"Learn corrections", L"0", L"Corrections", true},
        {L"Promotion threshold", L"2", L"Corrections", false},
        {L"Language", L"en_GB", L"General", false}};
    learning.config.context = &learningApplied;
    learning.config.callback = [](int action, const char *const *values, size_t count, void *context,
                                  char *, size_t) {
        auto &result = *static_cast<LearningApplied *>(context);
        ++result.calls;
        result.correct = action == 0 && count == 3 && std::string(values[0]) == "1" &&
            std::string(values[1]) == "3" && std::string(values[2]) == "en_GB";
        return 0;
    };
    HWND learningWindow = createDialog(owner, learning);
    if (!learningWindow) { error = "Could not create correction learning preferences."; return false; }
    const bool learningGrouped = learning.group == L"Corrections" && learningApplied.calls == 0 &&
        (GetWindowLongW(GetDlgItem(learningWindow, fieldBase), GWL_STYLE) & WS_VISIBLE) &&
        (GetWindowLongW(GetDlgItem(learningWindow, fieldBase + 1), GWL_STYLE) & WS_VISIBLE) &&
        !(GetWindowLongW(GetDlgItem(learningWindow, fieldBase + 2), GWL_STYLE) & WS_VISIBLE);
    SendDlgItemMessageW(learningWindow, fieldBase, BM_SETCHECK, BST_CHECKED, 0);
    SetDlgItemTextW(learningWindow, fieldBase + 1, L"3");
    SendMessageW(learningWindow, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool learningSaved = !IsWindow(learningWindow) && learningApplied.calls == 1 && learningApplied.correct;
    if (IsWindow(learningWindow)) DestroyWindow(learningWindow);
    if (!learningGrouped || !learningSaved) {
        error = "Correction learning preferences lost initial grouping or hidden preference values.";
        return false;
    }
    struct Applied { int calls = 0; bool correct = false; } applied;
    Dialog dialog;
    dialog.config.fields = {{L"Language", L"en_GB", L"Transcription", false}, {L"HUD", L"1", L"General", true}};
    dialog.config.fields.push_back({L"Full HUD size", L"expanded", L"General", false,
        {{L"compact", L"Compact"}, {L"expanded", L"Always Expanded"}, {L"autoExpand", L"Auto-Expand"}}});
    dialog.config.context = &applied;
    dialog.config.callback = [](int action, const char *const *values, size_t count, void *context,
                                 char *error, size_t capacity) {
        auto &result = *static_cast<Applied *>(context);
        ++result.calls;
        if (action != 0 || count != 3 || std::string(values[0]) != "fr_FR") {
            return jsti::fail("Synthetic invalid language.", error, capacity);
        }
        result.correct = std::string(values[1]) == "0" && std::string(values[2]) == "autoExpand";
        return 0;
    };
    HWND window = createDialog(owner, dialog);
    if (!window) { error = "Could not create the configuration fixture."; return false; }
    const bool initiallyGrouped = dialog.group == L"General" &&
        !(GetWindowLongW(GetDlgItem(window, fieldBase), GWL_STYLE) & WS_VISIBLE) &&
        (GetWindowLongW(GetDlgItem(window, fieldBase + 1), GWL_STYLE) & WS_VISIBLE);
    SendDlgItemMessageW(window, groupID, CB_SETCURSEL, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(groupID, CBN_SELCHANGE), 0);
    const bool switchedGroup = dialog.group == L"Transcription" &&
        (GetWindowLongW(GetDlgItem(window, fieldBase), GWL_STYLE) & WS_VISIBLE) &&
        !(GetWindowLongW(GetDlgItem(window, fieldBase + 1), GWL_STYLE) & WS_VISIBLE);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool refused = IsWindow(window) && applied.calls == 1 && text(window, problemID) == L"Synthetic invalid language.";
    SetDlgItemTextW(window, fieldBase, L"fr_FR");
    SendDlgItemMessageW(window, fieldBase + 1, BM_SETCHECK, BST_UNCHECKED, 0);
    const bool choicePopulated = SendDlgItemMessageW(window, fieldBase + 2, CB_GETCOUNT, 0, 0) == 3 &&
        SendDlgItemMessageW(window, fieldBase + 2, CB_GETCURSEL, 0, 0) == 1;
    SendDlgItemMessageW(window, fieldBase + 2, CB_SETCURSEL, 2, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool accepted = !IsWindow(window) && applied.calls == 2 && applied.correct;
    if (IsWindow(window)) DestroyWindow(window);
    Dialog cancelled;
    cancelled.config = dialog.config;
    HWND second = createDialog(owner, cancelled);
    if (second) SendMessageW(second, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
    const bool quiet = second && !IsWindow(second) && applied.calls == 2;
    if (!initiallyGrouped || !switchedGroup || !refused || !accepted || !quiet || !choicePopulated) {
        error = "Configuration editor did not group, validate, apply or cancel its native fields correctly.";
        return false;
    }
    Dialog recovery;
    recovery.config = dialog.config;
    recovery.group = L"Transcription";
    recovery.config.recovered = {L"First recoverable edit", L"Second recoverable edit"};
    recovery.config.callback = [](int action, const char *const *values, size_t count, void *context,
                                   char *error, size_t capacity) {
        auto &result = *static_cast<Applied *>(context);
        if (action != 3 || count != 4 || std::string(values[0]) != "en_GB" ||
            std::string(values[2]) != "expanded" || std::string(values[3]) != "Second recoverable edit")
            return jsti::fail("Recovery selected the wrong edit.", error, capacity);
        ++result.calls;
        return 0;
    };
    HWND recoveryWindow = createDialog(owner, recovery);
    if (!recoveryWindow) { error = "Could not create the keyword recovery fixture."; return false; }
    const bool offered = (GetWindowLongW(GetDlgItem(recoveryWindow, recoveryID), GWL_STYLE) & WS_VISIBLE) &&
        SendDlgItemMessageW(recoveryWindow, recoveryID, CB_GETCOUNT, 0, 0) == 2;
    SendDlgItemMessageW(recoveryWindow, recoveryID, CB_SETCURSEL, 1, 0);
    SendMessageW(recoveryWindow, WM_COMMAND, MAKEWPARAM(restoreID, BN_CLICKED), 0);
    const bool restored = !IsWindow(recoveryWindow) && applied.calls == 3;
    if (IsWindow(recoveryWindow)) DestroyWindow(recoveryWindow);
    if (!offered || !restored) {
        error = "Recovered keyword picker did not emit the selected edit with current preference fields.";
        return false;
    }
    Dialog sounds;
    sounds.config.fields = {
        {L"Recording sounds", L"0", L"General", true},
        {L"Sound profile", L"classic", L"General", false,
            {{L"classic", L"Classic"}, {L"bubbly", L"Bubbly"}, {L"futuristic", L"Futuristic"}, {L"soft", L"Soft"}}},
        {L"Volume", L"0.7", L"General", false}
    };
    sounds.config.context = &applied;
    sounds.config.callback = [](int action, const char *const *values, size_t count, void *context,
                                  char *error, size_t capacity) {
        if ((action != 4 && action != 5) || count != 3 || std::string(values[0]) != "0" ||
            std::string(values[1]) != "soft" || std::string(values[2]) != "0.25")
            return jsti::fail("Recording sound preview did not snapshot the edited preferences.", error, capacity);
        ++static_cast<Applied *>(context)->calls;
        return 0;
    };
    HWND soundWindow = createDialog(owner, sounds);
    if (!soundWindow) { error = "Could not create recording sound preferences fixture."; return false; }
    const bool profiles = SendDlgItemMessageW(soundWindow, fieldBase + 1, CB_GETCOUNT, 0, 0) == 4;
    SendDlgItemMessageW(soundWindow, fieldBase + 1, CB_SETCURSEL, 3, 0);
    SetDlgItemTextW(soundWindow, fieldBase + 2, L"0.25");
    SendMessageW(soundWindow, WM_COMMAND, MAKEWPARAM(previewStartID, BN_CLICKED), 0);
    SendMessageW(soundWindow, WM_COMMAND, MAKEWPARAM(previewStopID, BN_CLICKED), 0);
    const bool previewed = IsWindow(soundWindow) && applied.calls == 5;
    if (IsWindow(soundWindow)) DestroyWindow(soundWindow);
    if (!profiles || !previewed) {
        error = "Recording sound preferences did not offer all profiles or emit both previews.";
        return false;
    }
    Dialog overflow;
    Dialog commands;
    commands.config.fields = {
        {L"Enable voice commands", L"0", L"General", true},
        {L"Clipboard triggers", L"my snippet", L"General", false, {}, false, 1}
    };
    HWND commandWindow = createDialog(owner, commands);
    if (!commandWindow) { error = "Could not create voice command preferences fixture."; return false; }
    const bool commandsDisabled = !IsWindowEnabled(GetDlgItem(commandWindow, fieldBase + 1));
    SendDlgItemMessageW(commandWindow, fieldBase, BM_SETCHECK, BST_CHECKED, 0);
    SendMessageW(commandWindow, WM_COMMAND, MAKEWPARAM(fieldBase, BN_CLICKED), 0);
    const bool enabled = IsWindowEnabled(GetDlgItem(commandWindow, fieldBase + 1));
    SendDlgItemMessageW(commandWindow, fieldBase, BM_SETCHECK, BST_UNCHECKED, 0);
    SendMessageW(commandWindow, WM_COMMAND, MAKEWPARAM(fieldBase, BN_CLICKED), 0);
    const bool retained = !IsWindowEnabled(GetDlgItem(commandWindow, fieldBase + 1)) &&
        text(commandWindow, fieldBase + 1) == L"my snippet";
    DestroyWindow(commandWindow);
    if (!commandsDisabled || !enabled || !retained) {
        error = "Voice command toggle did not enable/disable its retained trigger editor.";
        return false;
    }
    overflow.group = L"Transcription";
    for (int i = 0; i < 12; ++i)
        overflow.config.fields.push_back({L"Preference", L"0.05", L"Transcription", false});
    overflow.config.fields.push_back({L"Hands-free sound activation", L"1", L"Transcription", true, {}, true});
    overflow.config.recovered = {L"Recoverable edit"};
    HWND overflowWindow = createDialog(owner, overflow);
    if (!overflowWindow) { error = "Could not create scrolling preferences fixture."; return false; }
    RECT before{}, after{}, recoveryBounds{}, client{};
    GetWindowRect(GetDlgItem(overflowWindow, IDOK), &before);
    SendMessageW(overflowWindow, WM_VSCROLL, SB_BOTTOM, 0);
    GetWindowRect(GetDlgItem(overflowWindow, IDOK), &after);
    GetWindowRect(GetDlgItem(overflowWindow, restoreID), &recoveryBounds);
    MapWindowPoints(nullptr, overflowWindow, reinterpret_cast<POINT *>(&recoveryBounds), 2);
    GetClientRect(overflowWindow, &client);
    const bool reached = (GetWindowLongW(GetDlgItem(overflowWindow, restoreID), GWL_STYLE) & WS_VISIBLE) &&
        (GetWindowLongW(GetDlgItem(overflowWindow, fieldBase + 12), GWL_STYLE) & WS_VISIBLE) &&
        recoveryBounds.bottom <= client.bottom - scale(overflowWindow, 112) &&
        EqualRect(&before, &after) &&
        IsWindowEnabled(GetDlgItem(overflowWindow, fieldBase + 12));
    SendMessageW(overflowWindow, WM_VSCROLL, SB_TOP, 0);
    const bool returned = (GetWindowLongW(GetDlgItem(overflowWindow, fieldBase), GWL_STYLE) & WS_VISIBLE) &&
        !(GetWindowLongW(GetDlgItem(overflowWindow, restoreID), GWL_STYLE) & WS_VISIBLE);
    DestroyWindow(overflowWindow);
    if (!reached || !returned) {
        error = "Preferences scrolling did not expose the last field and recovery controls above the fixed footer.";
        return false;
    }
    overflow.config.fields[12].value = L"0";
    overflowWindow = createDialog(owner, overflow);
    if (!overflowWindow) { error = "Could not create disabled hands-free preferences fixture."; return false; }
    const bool disabled = IsWindowEnabled(GetDlgItem(overflowWindow, fieldBase + 12)) ==
        (jsti_window_hands_free_guard_ready() != 0);
    DestroyWindow(overflowWindow);
    if (!disabled) {
        error = "Unavailable hands-free preferences allowed enabling a new unmonitored mode.";
        return false;
    }
    return true;
}
