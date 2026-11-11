// Private to the WindowsWindow*.cpp translation units: the main window's shared
// state, control identifiers and the functions one unit calls in another.
// Nothing here is public ABI; Swift sees only include/CWindowsSupport.h.
#pragma once

#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commctrl.h>
#include <commdlg.h>
#include <cstdio>
#include <cstring>
#include <objbase.h>
#include <shellapi.h>
#include <shlobj.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <mutex>
#include <limits>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <atomic>
#include <wtsapi32.h>

#include "WindowsHUD.hpp"
#include "WindowsTray.hpp"
#include "WindowsLoginItem.hpp"
#include "WindowsWindowChrome.hpp"
#include "WindowsHistoryFilters.hpp"
#include "WindowsOnboarding.hpp"
#include "WindowsAppIcon.hpp"
#include "WindowsMigrationRestore.hpp"
#include "WindowsGlobalEscape.hpp"

bool jsti_issue_report_attach(HWND owner, JSTIWindowCallback callback, void *context);
void jsti_issue_report_shutdown();
bool jsti_issue_report_message(MSG *message);
bool jsti_issue_report_self_test(std::string &error);

bool jsti_postprocessing_available();
void jsti_show_postprocessing(HWND owner);
bool jsti_settings_self_test(HWND owner, std::string &error);
bool jsti_profiles_self_test(HWND owner, std::string &error);
void jsti_show_profiles(HWND owner);
void jsti_show_comparison(HWND owner, JSTIWindowCallback callback, void *context);
bool jsti_comparison_self_test(HWND owner, std::string &error, const std::string &directory = {});
void jsti_cancel_profiles_request();
bool jsti_text_output_available();
void jsti_show_text_output(HWND owner);
bool jsti_text_output_settings_self_test(HWND owner, int button, void (*setRecording)(HWND, int),
                                         bool (*recordingBlocked)(HWND, void *), void *context, std::string &error);
bool jsti_hotkey_available();
bool jsti_hotkey_reserves_sidebar_digit(int digit);
std::wstring jsti_hotkey_label();
bool jsti_hotkey_start(HWND window, std::string &failure);
void jsti_hotkey_stop(HWND window);
bool jsti_hotkey_message(HWND window, UINT message, WPARAM wparam);
void jsti_show_hotkey_settings(HWND owner);
bool jsti_hotkey_self_test(HWND owner, int (*observe)(void *), void *context, std::string &error);
bool jsti_action_shortcuts_available();
bool jsti_action_shortcuts_start(HWND owner, std::string &failure);
void jsti_action_shortcuts_stop();
void jsti_action_shortcuts_request_refresh();
bool jsti_action_shortcut_key_message(HWND window, const MSG &message);
void jsti_show_action_shortcuts(HWND owner);
bool jsti_action_shortcuts_self_test(HWND owner, std::string &error);
bool jsti_voice_output_available();
void jsti_show_voice_settings(HWND owner);
bool jsti_voice_settings_self_test(HWND owner, std::string &error);
void jsti_show_voice_sources(HWND owner, const char *record, const char *history);
bool jsti_voice_sources_self_test(HWND owner, std::string &error);
void jsti_voice_sources_stop();
bool jsti_voice_credentials_available();
void jsti_show_voice_credentials(HWND owner);
bool jsti_voice_credentials_self_test(HWND owner, std::string &error);
bool jsti_azure_resource_available();
void jsti_show_configuration(HWND owner, const wchar_t *group);
void jsti_show_configuration_field(HWND owner, size_t index);
bool jsti_configuration_field_available(size_t index);
void jsti_show_azure_resource_settings(HWND owner);
bool jsti_azure_resource_settings_self_test(HWND owner, std::string &error);
bool jsti_configuration_self_test(HWND owner, std::string &error);
bool jsti_local_models_available();
std::wstring jsti_local_models_summary();
void jsti_show_local_models(HWND owner);
bool jsti_local_models_self_test(HWND owner, std::string &error);
bool jsti_api_keys_available();
void jsti_show_api_keys(HWND owner);
bool jsti_api_keys_self_test(HWND owner, std::string &error);
bool jsti_cloud_sync_available();
void jsti_show_cloud_sync_settings(HWND owner);
bool jsti_cloud_sync_settings_self_test(HWND owner, std::string &error);
int jsti_window_recording_state();
void jsti_show_vocabulary(HWND owner, int kind, void (*emit)(int, const char *, int));
void jsti_show_vocabulary_result(HWND owner, const char *record, void (*emit)(int, const char *, int));
bool jsti_vocabulary_self_test(HWND owner, std::string &error);
void jsti_show_automation_settings(HWND owner, bool (*enabled)(), void (*toggle)(HWND owner));
bool jsti_automation_settings_self_test(HWND owner, std::string &error);
void jsti_show_system_resources(HWND owner, void (*emit)(HWND owner, int event, const char *text));
bool jsti_system_resources_self_test(HWND owner, std::string &error);

int jsti_owned_window_save_snapshot(HWND window, const char *path, char *error, size_t errorCapacity);
// WindowsWindowBridge.cpp; also called by the action shortcuts and the self-test.
void jsti_window_action_command(HWND window, int run, const char *page);

namespace jsti_window {

constexpr UINT updateMessage = WM_APP + 1;
constexpr UINT profilesMessage = WM_APP + 17;
constexpr UINT guideMessage = WM_APP + 86, permissionsMessage = WM_APP + 87;
constexpr UINT audioCleanupMessage = WM_APP + 23;
constexpr int hotkeyID = 1;
constexpr int modelRefreshID = 140;
constexpr int modelStatusID = 141;
enum Control {
    modelID = 100, keyID, saveID, recordID, importID, copyID, transcriptID, statusID,
    historyID, historyDetailID, retryID, exportID, openAudioID, processingID, microphoneID, modeID,
    searchID, clearSearchID, variantID, profilesID = 150
};
constexpr int searchLabelID = 96;
constexpr int variantLabelID = 97;
// Native History playback controls. Explicit reserved identifiers, outside the
// implicit Control enumeration, so existing control identities never shift.
constexpr int playbackLabelID = 98;
constexpr int playPauseID = 160;
constexpr int stopPlaybackID = 161;
constexpr int playbackTimeID = 162;
// Opens the native Text output dialog directly; it emits no window event.
constexpr int textOutputID = 170;
// Opens the native Shortcut dialog directly; it emits no window event.
constexpr int shortcutID = 171;
// Opens the native Action shortcuts dialog (WindowsActionShortcuts.cpp).
constexpr int actionShortcutsID = 478;
constexpr int transcriptLabelID = 92;
// Zero-size label created just before the transcript field, so UI Automation names it "Transcript".
constexpr int transcriptNameID = 88;
// Read aloud emits an event; Voice… opens the native Voice output dialog.
constexpr int readAloudID = 172;
constexpr int voiceSettingsID = 173;
constexpr int correctionsID = 180, pronunciationID = 181;
constexpr int historyCorrectionsID = 182;
constexpr int voiceSourcesID = 184;
constexpr int voiceCredentialID = 185;
// The Source picker (Remote/Local) and the Local models dialog button, which
// takes the place of Refresh models while the Local source is selected.
constexpr int sourceLabelID = 89;
constexpr int localModelsID = 174;
constexpr int historyFiltersID = 460;
constexpr int historyDeleteID = 461, historyClearID = 462;
constexpr int issueReportID = 492;
constexpr int recordingsFolderLabelID = 463, recordingsFolderID = 464;
constexpr int audioCleanupID = 465;
constexpr int backupAudioID = 466, backupExportID = 467;
constexpr int backupInspectID = 468;
constexpr int backupRestoreID = 476;
constexpr int backupProfilesID = 469;
constexpr int automationSettingsID = 489;
// Opens System resources in use. It stays enabled while recording: releasing
// the microphone mid-recording is what it is for.
constexpr int systemResourcesID = 498;
constexpr int sourceID = 175;
constexpr int comparisonID = 183;
// Model modes: bit 0 is live, bit 1 is local (on-device).
constexpr int modeCount = 4;
constexpr int playbackIdle = 0, playbackPreparing = 1, playbackPlaying = 2, playbackPaused = 3;
const wchar_t *const playbackIdleText = L"00:00.00 / --:--";
// Pages, in sidebar order, as on the Mac: Speak, then Settings.
enum Page { dashboardPage, historyPage, voicePage, generalPage, transcriptionPage, postProcessingPage,
            correctionsPage, pronunciationPage, profilesPage, keyboardPage, cloudSyncPage, aboutPage, pageCount };
struct PageInfo { const wchar_t *title; const wchar_t *subtitle; wchar_t glyph; const char *name; };
const PageInfo pageInfo[pageCount] = {
    {L"Dashboard", L"Ready to capture ideas instantly. Check your setup, follow your usage, and pick up your latest "
                   L"session.", 0xE80F, "dashboard"},
    {L"History", L"Search, replay and reuse past recordings and their transcripts.", 0xE81C, "history"},
    {L"Voice Output", L"Read History, typed text, clipboard snapshots or imported text with your selected voice. "
                      L"Export lossless WAV audio.", 0xE767, "voice-output"},
    {L"General", L"Choose the microphone, where finished text goes, whether the app starts at login, and how it "
                 L"looks.", 0xE713, "general"},
    {L"Transcription", L"Pick the speech model for new recordings, on this PC or with your own provider key.", 0xE720,
     "transcription"},
    {L"Post-processing", L"Optionally polish transcripts with an OpenRouter model. The original is always kept.", 0xE734,
     "post-processing"},
    {L"Corrections", L"Your preferred spellings, applied before optional post-processing.", 0xE8D2, "corrections"},
    {L"Pronunciation", L"Your dictionary for Read aloud. Entries stay on this device.", 0xE82D, "pronunciation"},
    {L"Profiles", L"Give specific apps their own model, language and clean-up prompt.", 0xE77B, "profiles"},
    {L"Keyboard", L"Start and stop dictation from anywhere with a global shortcut.", 0xE765, "keyboard"},
    {L"iCloud Sync", L"Keep History in step with your Mac, through your own iCloud account.", 0xE753, "icloud-sync"},
    {L"About", L"Voice-to-text made simple. Windows developer preview.", 0xE946, "about"},
};
static_assert(JSTI_PAGE_COUNT == pageCount && JSTI_PAGE_CORRECTIONS == correctionsPage &&
    JSTI_PAGE_PRONUNCIATION == pronunciationPage && JSTI_PAGE_PROFILES == profilesPage &&
    JSTI_PAGE_ABOUT == aboutPage, "JSTI_PAGE_* must follow the sidebar's page order.");
// Sidebar buttons are navBaseID + page. The values in the heroes, Insights and
// Setup are owner-drawn static controls, so screen readers read them.
constexpr int navBaseID = 300;
constexpr int chipSessionsID = 401, chipTimeID = 402, chipSpendID = 403;
constexpr int insightSessionsID = 411, insightTimeID = 412, insightAverageID = 413, insightSpendID = 414;
constexpr int historySessionsID = 421, historyErrorsID = 422, historyAverageID = 423, historySpendID = 424;
constexpr int setupMicrophoneID = 431, setupModelID = 432, setupShortcutID = 433, setupOutputID = 434;
// Settings that were menu commands: the automation switch emits
// AUTOMATION_TOGGLED; the others open the same dialogs as before.
constexpr int appearanceLabelID = 440, appearanceID = 441, automationID = 442, azureID = 443, cloudSyncID = 444,
    shortcutValueID = 445, loginItemID = 449,
    configurationID = 450;
constexpr int aboutLinkBaseID = 480, aboutDetailsID = 490;
constexpr int setupGuideID = 451, permissionsID = 452, troubleshootingID = 453;
constexpr UINT tourMessage = WM_APP + 18, appearanceMessage = WM_APP + 19, pageMessage = WM_APP + 20;
constexpr UINT hudMessage = WM_APP + 21;
constexpr UINT sidebarMessage = WM_APP + 30;
constexpr UINT densityMessage = WM_APP + 31;
constexpr UINT shellMessage = WM_APP + 32;
// The API keys dialog opens from its Transcription button or the host's
// openAPIKeys() request (jsti_window_request_api_keys).
constexpr int apiKeysID = 491;
constexpr UINT apiKeysMessage = WM_APP + 98;
// The sidebar's settings search: its label (the box's accessible name), the box,
// the results list and the empty state. UI Automation exposes these control IDs
// as the elements' AutomationId, so they stay fixed.
constexpr int settingsSearchLabelID = 494, settingsSearchID = 495, settingsResultsID = 496,
    settingsNoMatchID = 497;
// Results from jsti_window_set_settings_search_results, a field reveal from
// jsti_window_reveal_configuration_field, and a deferred focus-loss check.
constexpr UINT settingsSearchMessage = WM_APP + 120, revealFieldMessage = WM_APP + 121,
    settingsLeaveMessage = WM_APP + 122;
constexpr size_t maximumSettingsResults = 50;
struct SidebarBindings {
    int digits[pageCount];
    std::wstring hints[pageCount];
    bool showHints = false;
    SidebarBindings() { std::fill(std::begin(digits), std::end(digits), -1); }
};

// Delivery is protected by WindowState::mutex; applied bindings remain UI-thread-only.
template<typename Payload, UINT Message>
struct WindowDelivery {
    std::unique_ptr<Payload> initial;
    std::unordered_map<UINT_PTR, std::unique_ptr<Payload>> posted;
    UINT_PTR sequence = 0;

    int stage(HWND window, std::unique_ptr<Payload> update) {
        if (!window) {
            initial = std::move(update);
            return 0;
        }
        if (sequence == std::numeric_limits<UINT_PTR>::max()) return -1;
        const UINT_PTR token = ++sequence;
        posted.emplace(token, std::move(update));
        if (PostMessageW(window, Message, token, 0)) return 0;
        posted.erase(token);
        return -1;
    }

    std::unique_ptr<Payload> claimInitial() { return std::move(initial); }

    std::unique_ptr<Payload> claim(UINT_PTR token) {
        const auto found = posted.find(token);
        if (found == posted.end()) return {};
        auto update = std::move(found->second);
        posted.erase(found);
        return update;
    }

    void retire() { posted.clear(); }
};

using SidebarDelivery = WindowDelivery<SidebarBindings, sidebarMessage>;
using DensityDelivery = WindowDelivery<JSTIVisualDensity, densityMessage>;

// General > App visibility, in the shared DesktopAppVisibility order.
enum ShellVisibility : int { shellBoth = 0, shellTrayOnly = 1, shellTaskbarOnly = 2 };
struct ShellPresentation {
    int visibility = shellBoth;
    bool compact = false;
};
using ShellDelivery = WindowDelivery<ShellPresentation, shellMessage>;

constexpr UINT_PTR tourTimerID = 90;
// Recording state changes are spoken after queued HUD updates land, and only when the HUD is hidden.
constexpr UINT_PTR announceTimerID = 91;
// How each owner-drawn control is drawn.
enum class Role { label, caption, status, detail, chipValue, statValue, tileValue, value, button, primary, record,
                  heroButton, nav, toggle, link };
struct HistoryRow {
    std::string id;
    std::wstring title;
    std::wstring detail;
    // The card: the shared DesktopHistoryRowSummary's wording.
    std::wstring created, audio, cost, preview, models, context;
    int tone = 0;
};
struct HistoryPresentation {
    std::string record;
    int variant = -1;
    bool switchable = false;
    std::wstring transcript;
    std::wstring status;
};
struct MicrophoneRow { std::string id; std::wstring name; };
struct ModelRow { std::string id; std::wstring name; int mode = 0; int order = -1; };

// The window shell: lifetime, recording state, the event callback and
// navigation. Page state lives in each page's own file behind its header
// (WindowsWindow*Page.hpp); cross-thread fields stay under `mutex`.
struct WindowState {
    std::mutex mutex;
    HWND window = nullptr;
    bool running = false;
    bool posted = false;
    SidebarDelivery sidebarDelivery;
    DensityDelivery densityDelivery;
    ShellDelivery shellDelivery;
    int recording = 0;
    bool globalEscapeEnabled = false;
    bool cancelKeyHeld = false;
    JSTIWindowCallback callback = nullptr;
    void *context = nullptr;
    HFONT font = nullptr;
    std::vector<HWND> controls;
    // Pages and presentation (UI thread).
    int page = dashboardPage;
    SidebarBindings sidebar;
    std::unordered_map<int, bool> wanted;
    std::wstring headerSubtitle;
    int displayedRecording = 0;
    std::wstring traySummary;
};

// One settings search result, as the sidebar's results list shows it.
struct SettingsSearchRow { std::wstring title, detail; std::string identifier; };

void setShown(HWND window, int identifier, bool shown);
void layout(HWND window);
void invalidateBackdrop(HWND window);
// The painted backdrop (WindowsWindowPaint.cpp): WM_PRINTCLIENT's copy and its release.
void printBackdrop(HWND window, HDC target);
void releaseBackdrop();

void updateModelLayout(HWND window);

void showPage(HWND window, int page);

// ----------------------------------------------------------------- frame

// What WM_PAINT draws behind the controls, laid out with them.
struct Card { RECT rect; wchar_t glyph; std::wstring title; };
struct Chip { RECT rect; std::wstring label; };
struct Paragraph { RECT rect; std::wstring text; jsti::chrome::Font font; bool secondary; };
struct Frame {
    RECT sidebar{}, header{}, status{}, hero{}, speakHeading{}, settingsHeading{}, icon{}, searchHint{};
    jsti::chrome::Gradient gradient = jsti::chrome::Gradient::brand;
    std::wstring heroTitle, heroSubtitle;
    std::vector<Chip> chips;
    std::vector<Card> cards;
    std::vector<Chip> stats;
    std::vector<Card> tiles;
    std::vector<RECT> fields;
    std::vector<Paragraph> paragraphs;
};

// The last layout (WindowsWindowLayout.cpp), UI thread only: what WM_PAINT
// draws, every placed control's rectangle and the applied density.
const Frame &layoutFrame();
const std::unordered_map<int, RECT> &placedControls();
JSTIVisualDensity currentVisualDensity();
// Applies a density from the host and lays the window out again.
void applyVisualDensity(HWND window, const JSTIVisualDensity &density);

// The window shell, defined in WindowsWindow.cpp. Every other piece of window
// state is private to the file that owns it and reached through the functions below.
extern WindowState state;

// Defined in the WindowsWindow*.cpp translation units.
void startHandsFreeGuard(HWND window);
void stopHandsFreeGuard(HWND window);
// Why hands-free is suspended, as bits: 1 locked, 2 suspended, 4 disconnected (WindowsWindow.cpp).
void setHandsFreeAbsent(unsigned reason, bool absent);
unsigned handsFreeAbsenceBits();
// Replaces the bits and returns the previous ones; the self-test restores them with it.
unsigned exchangeHandsFreeAbsence(unsigned bits);
int configureShell(ShellDelivery &delivery, HWND window, int visibility, int compact);
int configureVisualDensity(DensityDelivery &delivery, HWND window, JSTIVisualDensity density);
int configureSidebarShortcuts(SidebarDelivery &delivery, HWND window,
                             const JSTISidebarShortcut *bindings, size_t count, int showHints);
void retireCleanupPreview();
std::string historyManagementIDs();
int selection(HWND window);
int activeSource();
bool hasModeChoice();
bool hasSourceChoice();
bool liveSelection(HWND window);
void updateSourceControls(HWND window);
void updateModelAvailability(HWND window, int recording);
bool idleControl(HWND window, int identifier);
bool populateModels(HWND window);
bool applyModelRows(HWND window, const std::vector<ModelRow> &rows);
void emit(HWND window, int event, const char *text = "");
bool automationShownEnabled();
void requestAutomationToggle(HWND window);
std::string selectedMicrophone(HWND window);
void emitRecording(HWND window);
// General > App visibility as applied (WindowsWindowShell.cpp), UI thread only.
void setShellPresentation(const ShellPresentation &presentation);
// The window lives in the notification area with no taskbar button.
bool isTrayResident();
void applyShell(HWND window);
void releaseShell();
void trayCommand(HWND window, UINT command);
void showFailure(HWND window, const std::string &message);
std::string selectedHistory(HWND window);
bool searching(HWND window);
void applyVariant(HWND window, int selected, bool switchable, int recording);
void applyPlayback(HWND window, int playback, const std::wstring &text, bool selected, int recording);
void updateHistoryControls(HWND window, int recording);
void invalidateHistoryPresentation(HWND window, bool resetVersion);
void emitHistory(HWND window, int event);
void searchChanged(HWND window);
void clearSearch(HWND window);
using jsti::chrome::scale;
int measuredSidebarWidth(HWND window);
int minimumWindowWidth(HWND window);
int minimumWindowHeight(HWND window);
bool onPage(int identifier, int page);
Role roleOf(HWND window, int identifier);
int densitySpace(HWND window, int normal, int compact);
RECT box(int x, int y, int width, int height);
int widthOf(const RECT &rect);
int heightOf(const RECT &rect);
std::wstring heroTitle(int page);
RECT cardBody(HWND window, const RECT &card);
// The sidebar's settings search (WindowsWindowNavigation.cpp), UI thread only.
bool settingsSearchOpen(HWND window);
// The row the results list shows at `index`, or null.
const SettingsSearchRow *settingsSearchRow(size_t index);
// Whether a chosen result asked for focus on its page; clears the request.
bool takeSettingsSearchFocusPage();
// Programmatic edits of the search box report no search.
bool settingsSearchSuppressed();
// The window closed: drop pending and shown results.
void retireSettingsSearch();
int settingsResultHeight(HWND window);
HDC backdropDC(HWND window);
std::wstring controlText(HWND control);
void drawControl(HWND window, const DRAWITEMSTRUCT &item);
void drawHistoryItem(HWND window, const DRAWITEMSTRUCT &item);
bool highContrast();
void drawSettingsResult(HWND window, const DRAWITEMSTRUCT &item);
HBRUSH brushFor(COLORREF color);
void applyTheme(HWND window);
void refreshFont(HWND window);
void applySidebarBindings(HWND window, const SidebarBindings &bindings);
void applySidebarBindings(HWND window);
void emitSettingsSearch(HWND window);
void closeSettingsSearch(HWND window, bool clear);
void leaveSettingsSearch(HWND window);
void applySettingsResults(HWND window);
bool settingsSearchKeyMessage(HWND window, const MSG &message);
bool settingsSearchMouseMessage(HWND window, MSG &message);
bool navigateSidebar(HWND window, int digit, bool exactControl, HWND focused);
bool sidebarKeyMessage(HWND window, const MSG &message);
bool cancelKey(HWND window, const MSG &message, bool plain, bool active);
bool cancelKeyMessage(HWND window, const MSG &message);
void refreshSetup(HWND window);
bool createControls(HWND window);
bool populateMicrophones(HWND window);
bool applyMicrophones(HWND window, std::vector<MicrophoneRow> rows);
void updateSettingsButtons(HWND window, int recording);
void applyUpdate(HWND window);
void emitMigrationInspection(const std::string &path);
void inspectMigrationBackup(HWND window);
void importAudio(HWND window);
int migrationBackupOptions(HWND window);
void emitMigrationBackup(HWND window, const std::string &path, int options);
void exportMigrationBackup(HWND window);
void tourShow(HWND window, int step);
// Starts the screenshot tour unless one is already running (WindowsWindowTour.cpp).
bool tourBegin(HWND window, const std::wstring &directory);
void tourStep(HWND window);
LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
} // namespace jsti_window

// Each translation unit sees the window namespace as the original single file
// saw its anonymous namespace.
using namespace jsti_window;
