// History page state, owned by WindowsWindowHistory.cpp. The host stages rows,
// versions, presentations and playback under WindowState::mutex; the UI thread
// takes them in one piece in applyUpdate. The displayed page is UI-thread only.
#pragma once

#include "WindowsWindowInternal.hpp"

namespace jsti_window {

// Everything the host staged since the UI thread last took it.
struct HistoryUpdate {
    bool rowsChanged = false;
    std::vector<HistoryRow> rows;
    // The host's selection when no user selection has happened since it was
    // staged (`explicitSelection`); otherwise the record already selected.
    std::string selection;
    bool explicitSelection = false;
    bool presentationChanged = false;
    HistoryPresentation presentation;
    bool variantChanged = false;
    std::string variantRecord;
    int variant = -1;
    bool variantSwitchable = false;
    bool playbackChanged = false;
    std::string playbackRecord;
    int playback = playbackIdle;
    std::wstring playbackText;
};

// Each of these requires the caller to hold WindowState::mutex.
void stageHistoryRows(std::vector<HistoryRow> rows, const std::string *selection);
void clearHistoryPlayback();
HistoryUpdate takeHistoryUpdate();
void resetHistoryPending();
// A user selection or version choice: a host selection staged before it no longer applies.
void noteHistoryInteraction();
// The selected record. The UI thread writes it under the mutex and may read it without.
const std::string &selectedHistoryRecord();
void setSelectedHistoryRecord(std::string record);

// The History page as displayed. UI thread only.
struct HistoryView {
    std::vector<HistoryRow> displayedHistory;
    // The last row was drawn and the next page was asked for.
    bool historyMoreRequested = false;
    int displayedVariant = -1;
    bool variantSwitchable = false;
    bool historyPresentationReady = false;
    int requestedVariant = -1;
    int displayedPlayback = playbackIdle;
    bool suppressSearchEvents = false;
};
HistoryView &historyView();

} // namespace jsti_window
