// Transcription page: the model and source pickers, model catalogue and microphones.
#include "WindowsWindowModelsPage.hpp"

namespace jsti_window {
namespace {
ModelsPageState modelChoices;
} // namespace

ModelsPageState &modelsState() { return modelChoices; }

int selection(HWND window) {
    const LRESULT index = SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0);
    return index == CB_ERR || static_cast<size_t>(index) >= modelsState().filteredModels.size()
        ? -1 : modelsState().filteredModels[static_cast<size_t>(index)];
}

int activeSource() { return modelsState().activeMode / 2; }

bool hasModeChoice() {
    const int source = activeSource() * 2;
    return modelsState().preferredModels[source] >= 0 && modelsState().preferredModels[source + 1] >= 0;
}

bool hasSourceChoice() {
    return (modelsState().preferredModels[0] >= 0 || modelsState().preferredModels[1] >= 0) &&
        (modelsState().preferredModels[2] >= 0 || modelsState().preferredModels[3] >= 0);
}

bool liveSelection(HWND window) {
    const int selected = selection(window);
    return selected >= 0 && static_cast<size_t>(selected) < modelsState().modelModes.size() &&
        modelsState().modelModes[selected] % 2 == 1;
}

// Remote shows OpenRouter discovery and Refresh models; Local shows the
// on-device runtime and the Local models dialog.
void updateSourceControls(HWND window) {
    const bool local = activeSource() == 1;
    setShown(window, modelRefreshID, !local);
    setShown(window, localModelsID, local);
    const std::wstring text = local ? jsti_local_models_summary() : modelsState().remoteModelStatus;
    wchar_t shown[1100] = {};
    GetDlgItemTextW(window, modelStatusID, shown, 1100);
    if (text != shown) SetDlgItemTextW(window, modelStatusID, text.c_str());
}

void updateModelAvailability(HWND window, int recording) {
    EnableWindow(GetDlgItem(window, modeID), recording == 0 && hasModeChoice());
    EnableWindow(GetDlgItem(window, sourceID), recording == 0 && hasSourceChoice());
    EnableWindow(GetDlgItem(window, localModelsID), recording == 0 && jsti_local_models_available());
    EnableWindow(GetDlgItem(window, modelID), recording == 0);
    EnableWindow(GetDlgItem(window, importID), recording == 0 && selection(window) >= 0 && !liveSelection(window));
}

bool idleControl(HWND window, int identifier) {
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    return recording == 0 && IsWindowEnabled(GetDlgItem(window, identifier));
}

bool populateModels(HWND window) {
    HWND combo = GetDlgItem(window, modelID);
    SendMessageW(combo, WM_SETREDRAW, FALSE, 0);
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    modelsState().filteredModels.clear();
    LRESULT selectedRow = CB_ERR;
    bool success = true;
    std::vector<size_t> visible;
    for (size_t index = 0; index < modelsState().modelNames.size(); ++index) {
        if (modelsState().modelModes[index] != modelsState().activeMode) continue;
        const int rank = index < modelsState().modelOrder.size() ? modelsState().modelOrder[index] : static_cast<int>(index);
        if (rank >= 0 || static_cast<int>(index) == modelsState().preferredModels[modelsState().activeMode]) visible.push_back(index);
    }
    auto rank = [](size_t index) {
        const int value = index < modelsState().modelOrder.size() ? modelsState().modelOrder[index] : static_cast<int>(index);
        return value < 0 ? (std::numeric_limits<int>::max)() : value;
    };
    std::stable_sort(visible.begin(), visible.end(), [&](size_t left, size_t right) { return rank(left) < rank(right); });
    for (const size_t index : visible) {
        const LRESULT row = SendMessageW(combo, CB_ADDSTRING, 0,
                                         reinterpret_cast<LPARAM>(modelsState().modelNames[index].c_str()));
        if (row == CB_ERR || row == CB_ERRSPACE) { success = false; break; }
        modelsState().filteredModels.push_back(static_cast<int>(index));
        if (static_cast<int>(index) == modelsState().preferredModels[modelsState().activeMode]) selectedRow = row;
    }
    if (selectedRow == CB_ERR || !success) {
        SendMessageW(combo, CB_RESETCONTENT, 0, 0);
        modelsState().filteredModels.clear();
        success = false;
    } else SendMessageW(combo, CB_SETCURSEL, static_cast<WPARAM>(selectedRow), 0);
    SendMessageW(combo, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(combo, nullptr, TRUE);
    const bool choice = hasModeChoice();
    const bool relayout = state.page == transcriptionPage &&
        (state.wanted.count(modeID) == 0 || state.wanted[modeID] != choice || state.wanted[sourceID] != hasSourceChoice());
    setShown(window, modeID, choice);
    setShown(window, 95, choice);
    SendDlgItemMessageW(window, modeID, CB_SETCURSEL, modelsState().activeMode % 2, 0);
    const bool sources = hasSourceChoice();
    setShown(window, sourceID, sources);
    setShown(window, sourceLabelID, sources);
    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, activeSource(), 0);
    const wchar_t *label = activeSource() == 1 ? L"On-device &transcription model"
        : (!choice && modelsState().activeMode == 1 ? L"Live &transcription model" : L"&Transcription model");
    SetDlgItemTextW(window, 90, label);
    updateSourceControls(window);
    int recording;
    { std::lock_guard<std::mutex> lock(state.mutex); recording = state.recording; }
    updateModelAvailability(window, recording);
    // The Model card grows or shrinks with the Source and Mode rows.
    if (relayout) layout(window);
    return success;
}

bool applyModelRows(HWND window, const std::vector<ModelRow> &rows) {
    if (rows.empty()) return true;
    bool changed = rows.size() != modelsState().modelNames.size();
    for (size_t index = 0; !changed && index < rows.size(); ++index) {
        changed = rows[index].name != modelsState().modelNames[index] || rows[index].mode != modelsState().modelModes[index] ||
            index >= modelsState().modelOrder.size() || rows[index].order != modelsState().modelOrder[index];
    }
    if (!changed) return true;
    const int selected = selection(window);
    if (selected >= 0) modelsState().preferredModels[modelsState().activeMode] = selected;
    const bool hadModeChoice = hasModeChoice() || hasSourceChoice();
    int oldPreferred[modeCount];
    std::copy(std::begin(modelsState().preferredModels), std::end(modelsState().preferredModels), oldPreferred);
    auto oldNames = modelsState().modelNames;
    auto oldModes = modelsState().modelModes;
    auto oldOrder = modelsState().modelOrder;
    std::vector<std::wstring> names;
    std::vector<int> modes, order;
    for (const auto &row : rows) {
        names.push_back(row.name);
        modes.push_back(row.mode);
        order.push_back(row.order);
    }
    modelsState().modelNames = std::move(names); modelsState().modelModes = std::move(modes); modelsState().modelOrder = std::move(order);
    for (size_t index = 0; index < rows.size(); ++index) {
        if (rows[index].order >= 0 && modelsState().preferredModels[rows[index].mode] < 0) {
            modelsState().preferredModels[rows[index].mode] = static_cast<int>(index);
        }
    }
    if (populateModels(window)) {
        if (hadModeChoice != (hasModeChoice() || hasSourceChoice())) updateModelLayout(window);
        return true;
    }
    std::copy(std::begin(oldPreferred), std::end(oldPreferred), modelsState().preferredModels);
    modelsState().modelNames = std::move(oldNames); modelsState().modelModes = std::move(oldModes); modelsState().modelOrder = std::move(oldOrder);
    populateModels(window);
    return false;
}

void updateModelLayout(HWND window) {
    RECT bounds{};
    GetWindowRect(window, &bounds);
    const int minimumHeight = minimumWindowHeight(window);
    if (bounds.bottom - bounds.top < minimumHeight) {
        SetWindowPos(window, nullptr, 0, 0, bounds.right - bounds.left, minimumHeight,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    layout(window);
}

// UI thread only. The persisted choice is an opaque ID, never a row index.
// Missing devices retain that choice; a programmatic rebuild emits no event.
bool populateMicrophones(HWND window) {
    HWND combo = GetDlgItem(window, microphoneID);
    SendMessageW(combo, WM_SETREDRAW, FALSE, 0);
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    LRESULT selected = CB_ERR;
    bool okay = true;
    for (size_t index = 0; index < modelsState().microphones.size(); ++index) {
        const auto &row = modelsState().microphones[index];
        const LRESULT added = SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(row.name.c_str()));
        if (added == CB_ERR || added == CB_ERRSPACE) { okay = false; break; }
        if (row.id == modelsState().microphoneSelection) selected = added;
    }
    SendMessageW(combo, CB_SETCURSEL, static_cast<WPARAM>(selected), 0);
    SendMessageW(combo, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(combo, nullptr, TRUE);
    return okay && selected != CB_ERR;
}

bool applyMicrophones(HWND window, std::vector<MicrophoneRow> rows) {
    const auto selected = std::find_if(rows.begin(), rows.end(), [](const auto &row) {
        return row.id == modelsState().microphoneSelection;
    });
    if (selected == rows.end()) {
        const auto previous = std::find_if(modelsState().microphones.begin(), modelsState().microphones.end(), [](const auto &row) {
            return row.id == modelsState().microphoneSelection;
        });
        std::wstring name = previous == modelsState().microphones.end() ? L"Previously selected microphone" : previous->name;
        const std::wstring defaultMarker = L" (system default)";
        const size_t marker = name.find(defaultMarker);
        if (marker != std::wstring::npos) name.erase(marker, defaultMarker.size());
        const std::wstring suffix = L" (unavailable)";
        if (name.size() < suffix.size() || name.substr(name.size() - suffix.size()) != suffix) name += suffix;
        rows.push_back({modelsState().microphoneSelection, std::move(name)});
    }
    auto previous = std::move(modelsState().microphones);
    modelsState().microphones = std::move(rows);
    if (populateMicrophones(window)) return true;
    modelsState().microphones = std::move(previous);
    populateMicrophones(window);
    return false;
}
} // namespace jsti_window

int jsti_window_set_model_modes(const int *rowModes, size_t count, int preferredBatch, int preferredLive,
                                int preferredLocal) {
    if (count > 10000 || (count && !rowModes)) return -1;
    try {
        std::vector<int> modes;
        if (count) modes.assign(rowModes, rowModes + count);
        if (std::any_of(modes.begin(), modes.end(), [](int mode) { return mode < 0 || mode >= modeCount; })) return -1;
        const int preferred[] = {preferredBatch, preferredLive, preferredLocal};
        for (int mode = 0; mode < 3; ++mode) {
            const int index = preferred[mode];
            if (index < -1 || (index >= 0 && (static_cast<size_t>(index) >= count || modes[index] != mode))) return -1;
        }
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.running) return -1;
        modelsState().configuredModelModes = std::move(modes);
        modelsState().configuredPreferredModels[0] = preferredBatch;
        modelsState().configuredPreferredModels[1] = preferredLive;
        modelsState().configuredPreferredModels[2] = preferredLocal;
        modelsState().configuredPreferredModels[3] = -1;
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_preferred_local_live_model(int index) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.running) return -1;
    const auto &modes = modelsState().configuredModelModes;
    if (index < -1 || (index >= 0 && (static_cast<size_t>(index) >= modes.size() || modes[index] != 3))) return -1;
    modelsState().configuredPreferredModels[3] = index;
    return 0;
}

int jsti_window_set_local_model_preferences(int batch, int live) {
    std::lock_guard<std::mutex> lock(state.mutex);
    const int values[] = {batch, live};
    for (int i = 0; i < 2; ++i) {
        const int index = values[i], mode = i + 2;
        if (index < -1) return -1;
        if (index < 0) continue;
        if (state.running) {
            if (static_cast<size_t>(index) >= modelsState().knownModelIdentities.size() ||
                modelsState().knownModelIdentities[index].second != mode) return -1;
        } else if (static_cast<size_t>(index) >= modelsState().configuredModelModes.size() ||
                   modelsState().configuredModelModes[index] != mode) return -1;
    }
    if (!state.running) {
        for (int i = 0; i < 2; ++i) if (values[i] >= 0) modelsState().configuredPreferredModels[i + 2] = values[i];
        return 0;
    }
    for (int i = 0; i < 2; ++i) if (values[i] >= 0) modelsState().pendingLocalModelPreferences[i] = values[i];
    modelsState().localModelPreferencesChanged = true;
    if (state.window && !state.posted) {
        state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
        if (!state.posted) return -1;
    }
    return 0;
}

int jsti_window_set_model_catalog(const JSTIModelRow *rows, size_t count, const char *status, int refreshing) {
    if (!rows || !count || count > 10000 || (refreshing != 0 && refreshing != 1)) return -1;
    try {
        std::vector<ModelRow> models;
        std::unordered_set<std::string> identifiers;
        std::unordered_set<int> ranks;
        std::wstring wideStatus;
        if (status && (!jsti::wide(status, wideStatus) || wideStatus.size() > 4096)) return -1;
        for (size_t index = 0; index < count; ++index) {
            const auto &row = rows[index];
            std::wstring id, name;
            if (!row.id || !row.name || !jsti::wide(row.id, id) || !jsti::wide(row.name, name) ||
                id.empty() || name.empty() || id.size() > 4096 || name.size() > 4096 ||
                (row.is_live != 0 && row.is_live != 1) || (row.is_local != 0 && row.is_local != 1) ||
                row.display_order < -1 ||
                row.display_order >= static_cast<int>(count) || !identifiers.insert(row.id).second ||
                (row.display_order >= 0 && !ranks.insert(row.display_order).second)) return -1;
            models.push_back({row.id, std::move(name), row.is_live + 2 * row.is_local, row.display_order});
        }
        std::vector<std::pair<std::string, int>> identities;
        for (const auto &row : models) identities.emplace_back(row.id, row.mode);
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.running) {
            if (modelsState().knownModelIdentities.empty() || count < modelsState().knownModelIdentities.size()) return -1;
            for (size_t index = 0; index < modelsState().knownModelIdentities.size(); ++index) {
                if (models[index].id != modelsState().knownModelIdentities[index].first ||
                    models[index].mode != modelsState().knownModelIdentities[index].second) return -1;
            }
        }
        modelsState().knownModelIdentities = std::move(identities);
        modelsState().pendingModels = std::move(models);
        modelsState().modelsChanged = true;
        modelsState().modelsRefreshing = refreshing != 0;
        if (status) modelsState().modelStatus = std::move(wideStatus);
        if (state.window && !state.posted) {
            state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
            if (!state.posted) return -1;
        }
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_microphones(const char *const *ids, const char *const *names, size_t count,
                                 const char *selectedID) {
    if (!ids || !names || !count || count > 512) return -1;
    try {
        std::vector<MicrophoneRow> devices;
        std::unordered_set<std::string> unique;
        bool found = false;
        const std::string selection = selectedID ? selectedID : "";
        for (size_t i = 0; i < count; ++i) {
            std::wstring identifier, name;
            if (!jsti::wide(ids[i], identifier) || !jsti::wide(names[i], name) || name.empty() ||
                identifier.size() > 4096 || name.size() > 4096 || !unique.insert(ids[i]).second) return -1;
            devices.push_back({ids[i], std::move(name)});
            if (devices.back().id == selection) found = true;
        }
        if (!found) return -1;
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.running) return -1;
        modelsState().microphones = std::move(devices);
        modelsState().microphoneSelection = selection;
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_refresh_microphones(const JSTIAudioDevice *devices, size_t count, const char *error) {
    if ((!devices && count) || count > 512) return -1;
    try {
        std::vector<MicrophoneRow> copied;
        std::wstring warning;
        if (error) {
            if (!jsti::wide(error, warning) || warning.empty() || warning.size() > 4096) return -1;
        } else {
            std::unordered_set<std::string> identifiers;
            std::wstring defaultName;
            copied.push_back({"", L"Default communications microphone"});
            for (size_t index = 0; index < count; ++index) {
                std::wstring identifier, name;
                if (!jsti::wide(devices[index].id, identifier) || identifier.empty() || identifier.size() > 4096 ||
                    !jsti::wide(devices[index].name, name) || name.empty() || name.size() > 4096 ||
                    !identifiers.insert(devices[index].id).second ||
                    (devices[index].is_default != 0 && devices[index].is_default != 1)) return -1;
                if (devices[index].is_default) {
                    if (!defaultName.empty()) return -1;
                    defaultName = name;
                    name += L" (system default)";
                }
                copied.push_back({devices[index].id, std::move(name)});
            }
            if (!defaultName.empty()) copied[0].name += L" — " + defaultName;
        }
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.window || !state.running) return -1;
        if (!error) modelsState().pendingMicrophones = std::move(copied);
        modelsState().microphoneError = std::move(warning);
        modelsState().microphonesChanged = true;
        if (!state.posted) state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
        return state.posted ? 0 : -1;
    } catch (...) { return -1; }
}
