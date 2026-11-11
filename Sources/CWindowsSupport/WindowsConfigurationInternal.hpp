// Dictation preferences (WindowsConfiguration.cpp): the field model and the
// dialog's pieces its self-test (CWindowsSelfTest) drives. Not public ABI.
#pragma once

#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <string>
#include <vector>

namespace jsti::configuration {

constexpr int groupLabelID = 598, groupID = 599, fieldBase = 600, labelBase = 700;
constexpr int problemID = 800, importID = 801, exportID = 802;
constexpr int recoveryLabelID = 803, recoveryID = 804, restoreID = 805;
constexpr int previewStartID = 806, previewStopID = 807;
constexpr size_t maximumConfigurationFields = 64;
static_assert(maximumConfigurationFields <= labelBase - fieldBase);
constexpr UINT refreshTitleMessage = WM_APP + 85;
constexpr UINT refreshSnapshotMessage = WM_APP + 86;
struct Field {
    std::wstring title, value, group;
    bool boolean = false;
    std::vector<std::pair<std::wstring, std::wstring>> choices{};
    bool requiresHandsFreeGuard = false;
    int enabledByField = 0;
    int availability = -1;
};
struct Configuration {
    std::vector<Field> fields;
    std::vector<std::wstring> recovered;
    JSTIConfigurationCallback callback = nullptr;
    void *context = nullptr;
    std::string revision;
};
struct Dialog {
    Configuration config;
    HFONT font = nullptr;
    std::vector<HWND> controls;
    std::vector<std::wstring> groups;
    std::wstring group = L"General";
    int scrollOffset = 0;
    bool pending = false;
};

// The host's latest description, guarded by configurationMutex, and the open
// editor, if any.
extern Configuration configuration;
extern std::mutex configurationMutex;
extern HWND activeConfiguration;

// A control's text.
std::wstring text(HWND window, int id);
HWND createDialog(HWND owner, Dialog &dialog);
// Scrolls field `index` of the shown group to the top of the view (as far as the
// scroll range allows) and focuses it. False when it is not in the shown group.
bool revealField(HWND window, Dialog &dialog, size_t index);

} // namespace jsti::configuration
