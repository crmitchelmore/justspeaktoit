#include "../CWindowsSupport/WindowsVocabularyInternal.hpp"
#include "../CWindowsSupport/WindowsWindowChrome.hpp"
#include "../CWindowsSupport/WindowsWindowInternal.hpp"

namespace jsti::vocabulary {
namespace {
using jsti::chrome::scale;

bool pronunciationFilterSelfTest(Dialog &d, std::string &captured, std::string &error) {
    const std::vector<Row> rows = {
        {"fixture-a", "Alpha", "First", "ReplacementOnly", "Technical", "false", "false", ""},
        {"fixture-b", "Beta", "Second", "Other", "Names", "false", "false", ""},
        {"fixture-u", "Gamma", "Third", "Other", "Imported", "false", "false", ""},
        {"fixture-n", "Delta", "Fourth", "", "", "false", "false", ""}
    };
    const std::string legacy = "\ttrue\ttrue\t";
    const std::string modern = legacy + "\tpronunciationCategories.v1\t4\tTechnical\t1\tNames\t1";
    auto present = [&](const std::string &header, const std::vector<Row> &values) {
        std::string payload = header;
        for (const auto &row : values) {
            payload += '\n';
            for (size_t i = 0; i < row.size(); ++i) payload += (i ? "\t" : "") + escaped(row[i]);
        }
        SendMessageW(d.window, update, 0, reinterpret_cast<LPARAM>(new Update{payload, true}));
    };
    auto expect = [&](bool condition, const char *message) {
        if (!condition) error = message;
        return condition;
    };
    auto choose = [&](size_t index) {
        SendDlgItemMessageW(d.window, categoryFilter, CB_SETCURSEL, index, 0);
        SendMessageW(d.window, WM_COMMAND, MAKEWPARAM(categoryFilter, CBN_SELCHANGE),
            reinterpret_cast<LPARAM>(GetDlgItem(d.window, categoryFilter)));
    };
    auto label = [&](size_t index) {
        wchar_t value[128]{};
        SendDlgItemMessageW(d.window, categoryFilter, CB_GETLBTEXT, index, reinterpret_cast<LPARAM>(value));
        return std::wstring(value);
    };
    present(modern, rows);
    if (!expect(d.visible.size() == 4 && d.categories.size() == 3 && label(0) == L"All (4)"
        && label(1) == L"Technical (1)" && label(2) == L"Names (1)", "Pronunciation category counts failed.")) return false;
    set(d.window, search, "rEpLaCeMeNtOnLy");
    if (!expect(d.visible == std::vector<int>{0}, "Replacement-only pronunciation search failed.")) return false;
    set(d.window, search, "Technical");
    if (!expect(d.visible.empty(), "Pronunciation search incorrectly searched category labels.")) return false;
    set(d.window, search, "");
    if (!expect(d.visible.size() == 4, "Clearing pronunciation search lost unknown or uncategorized entries.")) return false;
    SendDlgItemMessageW(d.window, list, LB_SETCURSEL, 1, 0);
    SendMessageW(d.window, WM_COMMAND, MAKEWPARAM(list, LBN_SELCHANGE),
        reinterpret_cast<LPARAM>(GetDlgItem(d.window, list)));
    choose(1);
    const auto previous = captured;
    action(d, "save");
    if (!expect(d.selected == 1 && d.visible == std::vector<int>{0}
        && !IsWindowEnabled(GetDlgItem(d.window, save)) && captured == previous
        && get(d.window, field) == "Beta", "A hidden pronunciation selection changed identity or remained writable.")) return false;
    set(d.window, search, "Second");
    if (!expect(d.visible.empty() && label(0) == L"All (4)" && label(1) == L"Technical (1)",
        "Pronunciation search and category filtering were not conjunctive.")) return false;
    set(d.window, search, "");
    choose(2);
    if (!expect(d.visible == std::vector<int>{1} && IsWindowEnabled(GetDlgItem(d.window, save)),
        "Clearing filters did not restore the selected pronunciation entry.")) return false;
    present(modern, {rows[1], rows[2], rows[0], rows[3]});
    if (!expect(d.category == "Names" && d.selected == 0 && d.visible == std::vector<int>{0},
        "Pronunciation reload did not preserve category and UUID identity.")) return false;
    action(d, "save");
    auto fields = split(captured, '\t');
    if (!expect(fields.size() == 9 && decoded(fields[1]) == "fixture-b",
        "Filtered pronunciation editing targeted another row.")) return false;
    present(legacy + "\tpronunciationCategories.v1\t3\tTechnical\t1", {rows[2], rows[0], rows[3]});
    if (!expect(d.category.empty() && d.selected == -1 && d.visible.size() == 3 && get(d.window, field).empty(),
        "A removed pronunciation category or entry was retained as another selection.")) return false;
    choose(1);
    present(legacy + "\tpronunciationCategories.v1\t0", {});
    if (!expect(d.category.empty() && d.visible.empty() && d.categories.size() == 1 && label(0) == L"All (0)",
        "An empty pronunciation collection did not reset its category filter.")) return false;
    present(legacy, rows);
    if (!expect(d.categories.size() == 1 && d.visible.size() == 4, "Legacy pronunciation payload handling failed.")) return false;
    const std::vector<std::string> invalid = {
        legacy + "\tpronunciationCategories.v2\t4",
        legacy + "\tpronunciationCategories.v1",
        legacy + "\tpronunciationCategories.v1\t4\tTechnical",
        legacy + "\tpronunciationCategories.v1\t-1",
        legacy + "\tpronunciationCategories.v1\t999999999999999999999",
        legacy + "\tpronunciationCategories.v1\t3",
        legacy + "\tpronunciationCategories.v1\t4\tTechnical\t-1",
        legacy + "\tpronunciationCategories.v1\t4\tTechnical\t0",
        legacy + "\tpronunciationCategories.v1\t4\tTechnical\t2",
        legacy + "\tpronunciationCategories.v1\t4\tTechnical\t01",
        legacy + "\tpronunciationCategories.v1\t4\tTechnical\t1\tTechnical\t1",
        legacy + "\tpronunciationCategories.v1\t4\t\t1"
    };
    for (const auto &header : invalid) {
        present(header, rows);
        if (!expect(d.busy && !IsWindowEnabled(GetDlgItem(d.window, save)) && d.rows.size() == 4
            && get(d.window, notice).find("Invalid pronunciation category metadata") == 0,
            "Malformed modern pronunciation metadata was not explicitly refused.")) return false;
        present(modern, rows);
    }
    MINMAXINFO minimum{};
    SendMessageW(d.window, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&minimum));
    SetWindowPos(d.window, nullptr, 0, 0, minimum.ptMinTrackSize.x, minimum.ptMinTrackSize.y,
        SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOZORDER);
    RECT bounds{}; GetWindowRect(d.window, &bounds);
    const auto dpi = GetDpiForWindow(d.window);
    SendMessageW(d.window, WM_DPICHANGED, MAKEWPARAM(dpi, dpi), reinterpret_cast<LPARAM>(&bounds));
    RECT client{}, filterBounds{}, listBounds{}, searchBounds{}, labelBounds{};
    GetClientRect(d.window, &client);
    GetWindowRect(GetDlgItem(d.window, categoryFilter), &filterBounds);
    GetWindowRect(GetDlgItem(d.window, list), &listBounds);
    GetWindowRect(GetDlgItem(d.window, search), &searchBounds);
    GetWindowRect(d.categoryLabel, &labelBounds);
    for (RECT *rect : {&filterBounds, &listBounds, &searchBounds, &labelBounds})
        MapWindowPoints(nullptr, d.window, reinterpret_cast<POINT *>(rect), 2);
    return expect(dpi > 0 && minimum.ptMinTrackSize.x == scale(d.window, 800)
        && minimum.ptMinTrackSize.y == scale(d.window, 480) && filterBounds.left >= 0
        && filterBounds.right <= client.right && searchBounds.bottom <= labelBounds.top
        && labelBounds.bottom <= filterBounds.top && filterBounds.bottom <= listBounds.top
        && GetWindow(GetDlgItem(d.window, categoryFilter), GW_HWNDPREV) == d.categoryLabel,
        "Pronunciation category controls exceeded minimum-size/DPI bounds or lost their accessible label.");
}

// jsti_vocabulary_set reaches only the active editor of the requested kind,
// refuses malformed input, and the editor's WM_DESTROY both retires it and
// frees an update still queued for it.
bool deliverySelfTest(HWND owner, std::string &error) {
    auto queued = [](HWND window) {
        MSG message{};
        return PeekMessageW(&message, window, update, update, PM_NOREMOVE) != FALSE;
    };
    if (jsti_vocabulary_set(-1, "", 1) != -1 || jsti_vocabulary_set(5, "", 1) != -1
        || jsti_vocabulary_set(0, nullptr, 1) != -1) {
        error = "Vocabulary updates accepted an invalid kind or payload."; return false;
    }
    Dialog dialog; dialog.kind = 4;
    dialog.emit = [](int, const char *, int) {};
    HWND window = createWindow(owner, dialog);
    if (!window) { error = "Vocabulary delivery fixture could not be created."; return false; }
    activateEditor(window, 4);
    bool valid = jsti_vocabulary_set(1, "other kind", 1) == 0 && !queued(window)
        && jsti_vocabulary_set(4, "queued for 4", 0) == 0 && queued(window);
    DestroyWindow(window);
    MSG thread{};
    valid = valid && !queued(window) && jsti_vocabulary_set(4, "after close", 0) == 0
        && !PeekMessageW(&thread, reinterpret_cast<HWND>(-1), update, update, PM_NOREMOVE);
    if (!valid) error = "Vocabulary updates reached a closed or different editor.";
    return valid;
}

bool editorsSelfTest(HWND owner, std::string &error) {
    static std::string captured;
    for (int kind = 0; kind < 5; ++kind) {
        Dialog dialog; dialog.kind = kind;
        dialog.emit = [](int event, const char *payload, int) { if (event == 70) captured = payload; };
        HWND window = createWindow(owner, dialog);
        if (!window) { error = "Vocabulary controls could not be created."; return false; }
        if (kind == 2) {
            set(window, notice, "Applied\nSynthetic -> Canonical\nSuggestions\nmanual\t%");
            const bool valid = get(window, notice) == "Applied\nSynthetic -> Canonical\nSuggestions\nmanual\t%";
            DestroyWindow(window);
            if (!valid) { error = "Correction results did not preserve readable multiline text."; return false; }
            continue;
        }
        if (kind == 3) {
            bool valid = dialog.busy && IsWindowEnabled(GetDlgItem(window, stopLearning))
                && !IsWindowEnabled(GetDlgItem(window, allowLearning));
            captured.clear();
            SendMessageW(window, WM_COMMAND, MAKEWPARAM(stopLearning, BN_CLICKED),
                reinterpret_cast<LPARAM>(GetDlgItem(window, stopLearning)));
            valid = valid && captured == "stopLearning" && dialog.busy
                && IsWindowEnabled(GetDlgItem(window, stopLearning))
                && !IsWindowEnabled(GetDlgItem(window, allowLearning))
                && get(window, notice) == "Stop requested; waiting for confirmation...";
            pending(dialog, false);
            valid = valid && IsWindowEnabled(GetDlgItem(window, allowLearning))
                && IsWindowEnabled(GetDlgItem(window, stopLearning));
            Row row{}; row[0] = "synthetic\t%"; row[1] = "Synthetic"; row[2] = "Canonical"; row[3] = "2";
            dialog.rows.push_back(row); dialog.selected = 0;
            fill(dialog, row); action(dialog, "promote");
            auto fields = split(captured, '\t');
            valid = valid && fields.size() == 2 && decoded(fields[1]) == row[0] && fields[0] == "promote";
            action(dialog, "clear"); valid = valid && captured == "clear";
            DestroyWindow(window);
            if (!valid) { error = "Stored candidate events or pending Stop learning availability failed."; return false; }
            continue;
        }
        if (kind == 4) {
            Row row{}; row[0] = "fixture-identity"; row[1] = "Word\t%"; row[2] = "Spoken\nform";
            dialog.rows.push_back(row); dialog.visible.push_back(0); dialog.selected = 0;
            fill(dialog, row); action(dialog, "save");
            auto fields = split(captured, '\t');
            bool valid = fields.size() == 4 && fields[0] == "save" && fields[1] == row[0]
                && decoded(fields[2]) == row[1] && decoded(fields[3]) == row[2]
                && !IsWindowEnabled(GetDlgItem(window, field))
                && !IsWindowEnabled(GetDlgItem(window, field + 1));
            pending(dialog, false);
            valid = valid && IsWindowEnabled(GetDlgItem(window, field))
                && IsWindowEnabled(GetDlgItem(window, field + 1));
            action(dialog, "delete"); fields = split(captured, '\t');
            valid = valid && fields.size() == 4 && fields[0] == "delete" && fields[1] == row[0];
            SendMessageW(window, WM_COMMAND, MAKEWPARAM(add, BN_CLICKED), 0);
            action(dialog, "save"); fields = split(captured, '\t');
            valid = valid && dialog.selected == -1 && fields.size() == 4 && fields[1].empty()
                && fields[2].empty() && fields[3].empty();
            DestroyWindow(window);
            if (!valid) { error = "Legacy dictionary did not preserve entry identity or escaped word/pronunciation."; return false; }
            continue;
        }
        Row row{}; row[1] = "Synthetic"; row[2] = "Canonical"; row[3] = "spoken\nvariant\t%";
        row[4] = kind == 0 ? "manual" : "Custom"; row[5] = kind == 0 ? "work" : "true";
        row[6] = kind == 0 ? "low" : "true"; row[7] = "fixture notes";
        fill(dialog, row); action(dialog, "save");
        auto fields = split(captured, '\t');
        bool valid = fields.size() == 9 && decoded(fields[2]) == row[1]
            && decoded(fields[4]) == row[3] && decoded(fields[5]) == row[4]
            && decoded(fields[7]) == row[6];
        set(window, preview, "Synthetic\t%\n"); set(window, previewTags, "work");
        action(dialog, "preview"); fields = split(captured, '\t');
        valid = valid && fields.size() == 3 && decoded(fields[1]) == "Synthetic\t%\n"
            && decoded(fields[2]) == "work";
        if (valid && kind == 1) valid = pronunciationFilterSelfTest(dialog, captured, error);
        DestroyWindow(window);
        if (!valid) {
            if (error.empty()) error = "Vocabulary editor did not preserve field or preview events.";
            return false;
        }
    }
    return true;
}
} // namespace
} // namespace jsti::vocabulary

bool jsti_vocabulary_self_test(HWND owner, std::string &error) {
    using namespace jsti::vocabulary;
    return deliverySelfTest(owner, error) && editorsSelfTest(owner, error);
}
