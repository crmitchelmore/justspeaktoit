// Voice Output sources (WindowsVoiceSources.cpp): the dialog's model, the
// host's staged state and the pieces its self-test (CWindowsSelfTest) drives.
// Not public ABI.
#pragma once

#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <string>
#include <vector>

namespace jsti::voiceSources {

enum { sourceLabel = 920, sourceID, textLabel, textID, loadID, noticeID, readID, exportID, stopID };
enum { autoPlayID = 940, saveID, generateID, playResultID, exportResultID, controlsID, usageID, discoveryID, helperID };
enum { markupListID = 990, markupTextID, markupCopyID, markupNoticeID, markupWrapID };
enum { formatLabelID = 970, formatID };
struct MarkupExample { std::wstring text, description; };
struct MarkupConfiguration {
    bool enabled = false;
    std::vector<MarkupExample> examples;
    JSTIVoiceMarkupWrapCallback wrap = nullptr;
};
struct Configuration {
    std::vector<std::wstring> names;
    JSTIVoiceSourceCallback callback = nullptr;
    void *context = nullptr;
};
struct GenerationState {
    int flags = 0;
    bool working = false;
    std::string resultID;
    std::wstring message;
    std::string format = "wav";
};
struct FormatState {
    std::vector<std::wstring> labels;
    std::vector<std::string> identifiers;
    int selected = -1;
    std::wstring status;
};
constexpr UINT generationMessage = WM_APP + 25;
constexpr UINT importResultMessage = WM_APP + 24;
constexpr UINT markupMessage = WM_APP + 28;
constexpr UINT formatMessage = WM_APP + 45;
struct ImportResult {
    HWND window = nullptr;
    std::string token;
    std::wstring text, error;
    bool ready = false;
};
struct Dialog {
    Configuration config;
    std::string record;
    std::wstring history, typed, clipboard, file;
    std::string importToken;
    GenerationState generation;
    FormatState formats;
    bool formatPending = false;
    int source = 0;
    HFONT font = nullptr;
    HWND markupWindow = nullptr;
    std::vector<HWND> controls;
};
struct MarkupDialog {
    HWND owner = nullptr;
    Dialog *source = nullptr;
    MarkupConfiguration config;
    HFONT font = nullptr;
    bool (*copy)(HWND, const std::wstring &, void *) = nullptr;
    void *copyContext = nullptr;
};

// The host's staged state is private to WindowsVoiceSources.cpp, behind its
// mutex. These take the lock; the self-test swaps fixtures in and out with them.
Configuration hostConfiguration();
MarkupConfiguration exchangeMarkupConfiguration(MarkupConfiguration next);
void setMarkupEnabled(bool enabled);
FormatState exchangeFormats(FormatState next);
GenerationState hostGeneration();
void replaceGeneration(GenerationState next);
// Waits for jsti_window_set_voice_text_import(token) to answer `window`.
void expectImport(HWND window, const std::string &token);

// The text box's contents.
std::wstring text(HWND window);
bool canEditMarkup(const Dialog &dialog);
void refresh(HWND window, Dialog &dialog);
std::string selectedFormat(const Dialog &dialog);
bool applyMarkup(HWND window, MarkupDialog &dialog);
HWND makeMarkupDialog(MarkupDialog &dialog);
void select(HWND window, Dialog &dialog);
void emit(HWND window, Dialog &dialog, int action, const std::string &path = "");
HWND makeDialog(HWND owner, Dialog &dialog);

} // namespace jsti::voiceSources
