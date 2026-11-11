// Transcription page state: microphones and model choices, owned by
// WindowsWindowModels.cpp and reached through modelsState(). Fields the
// host's jsti_window_* setters write are guarded by WindowState::mutex; the
// UI thread owns the rest.
#pragma once

#include "WindowsWindowInternal.hpp"

namespace jsti_window {

struct ModelsPageState {
    bool microphonesChanged = false;
    std::vector<MicrophoneRow> pendingMicrophones;
    std::wstring microphoneError;
    bool modelsChanged = false;
    bool localModelPreferencesChanged = false;
    int pendingLocalModelPreferences[2] = {-1, -1};
    bool modelsRefreshing = false;
    std::wstring modelStatus;
    std::vector<ModelRow> pendingModels;
    std::vector<std::pair<std::string, int>> knownModelIdentities;
    std::vector<MicrophoneRow> microphones;
    std::string microphoneSelection;
    std::vector<int> configuredModelModes;
    int configuredPreferredModels[4] = {-1, -1, -1, -1}; // Global remote batch, remote live, local batch and local live rows.
    std::vector<std::wstring> modelNames;
    std::vector<int> modelModes;
    std::vector<int> modelOrder;
    std::vector<int> filteredModels;
    int preferredModels[modeCount] = {-1, -1, -1, -1};
    int activeMode = 0;
    std::wstring remoteModelStatus;
};

ModelsPageState &modelsState();

} // namespace jsti_window
