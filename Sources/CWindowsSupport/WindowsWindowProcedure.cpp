// The main window procedure.
#include "WindowsWindowInternal.hpp"
#include "WindowsWindowAboutPage.hpp"
#include "WindowsWindowBackup.hpp"
#include "WindowsWindowGeneralPage.hpp"
#include "WindowsWindowHistoryPage.hpp"
#include "WindowsWindowModelsPage.hpp"

namespace jsti_window {

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_ACTIVATE:
        if (LOWORD(wparam) == WA_INACTIVE) state.cancelKeyHeld = false;
        if (HIWORD(wparam)) break;
        // Back from a dialog, the setup guide or another app, focus returns to a
        // control rather than the bare window, which screen readers cannot use.
        jsti::chrome::rememberFocus(window, wparam, state.focus, navBaseID + state.page);
        return 0;
    case WM_CREATE:
        jsti::accessibility::attach(window);
        if (!createControls(window)) return -1;
        startHandsFreeGuard(window);
        return 0;
    case WM_WTSSESSION_CHANGE:
        if (wparam == WTS_SESSION_LOCK || wparam == WTS_SESSION_LOGOFF ||
            wparam == WTS_CONSOLE_DISCONNECT || wparam == WTS_REMOTE_DISCONNECT) {
            setHandsFreeAbsent(wparam == WTS_SESSION_LOCK ? 1u : 4u, true);
            emit(window, JSTI_EVENT_USER_ABSENT, "session locked or disconnected");
        } else if (wparam == WTS_SESSION_UNLOCK || wparam == WTS_CONSOLE_CONNECT || wparam == WTS_REMOTE_CONNECT) {
            setHandsFreeAbsent(wparam == WTS_SESSION_UNLOCK ? 1u : 4u, false);
        }
        return 0;
    case WM_POWERBROADCAST:
        if (wparam == PBT_APMSUSPEND) {
            setHandsFreeAbsent(2u, true);
            emit(window, JSTI_EVENT_USER_ABSENT, "computer suspended");
        } else if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
            setHandsFreeAbsent(2u, false);
        }
        return TRUE;
    case WM_GETMINMAXINFO: {
        auto info = reinterpret_cast<MINMAXINFO *>(lparam);
        info->ptMinTrackSize = {minimumWindowWidth(window), minimumWindowHeight(window)};
        return 0;
    }
    case WM_SIZE:
        // Without a taskbar button a minimised window would sit above the
        // desktop; it goes to the notification area instead.
        if (wparam == SIZE_MINIMIZED && isTrayResident()) { ShowWindow(window, SW_HIDE); return 0; }
        layout(window); return 0;
    case WM_SYSCOMMAND:
        // Close and minimise keep a notification-area app running; Quit exits.
        if (isTrayResident() && ((wparam & 0xFFF0) == SC_CLOSE || (wparam & 0xFFF0) == SC_MINIMIZE)) {
            ShowWindow(window, SW_HIDE);
            return 0;
        }
        break;
    case WM_DPICHANGED: {
        std::string iconFailure;
        if (!jsti::appIcon::refresh(window, HIWORD(wparam), iconFailure)) showFailure(window, iconFailure);
        auto bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        refreshFont(window); layout(window); return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT paint{};
        HDC target = BeginPaint(window, &paint);
        HDC source = backdropDC(window);
        if (source) {
            BitBlt(target, paint.rcPaint.left, paint.rcPaint.top, paint.rcPaint.right - paint.rcPaint.left,
                   paint.rcPaint.bottom - paint.rcPaint.top, source, paint.rcPaint.left, paint.rcPaint.top, SRCCOPY);
        }
        EndPaint(window, &paint);
        return 0;
    }
    case WM_PRINTCLIENT:
        printBackdrop(window, reinterpret_cast<HDC>(wparam));
        return 0;
    case WM_MEASUREITEM: {
        auto item = reinterpret_cast<MEASUREITEMSTRUCT *>(lparam);
        if (item->CtlType == ODT_LISTBOX) item->itemHeight = static_cast<UINT>(
            item->CtlID == settingsResultsID ? settingsResultHeight(window) : scale(window, 132));
        return TRUE;
    }
    case WM_DRAWITEM: {
        const auto &item = *reinterpret_cast<const DRAWITEMSTRUCT *>(lparam);
        if (item.CtlType == ODT_LISTBOX && item.CtlID == settingsResultsID) drawSettingsResult(window, item);
        else if (item.CtlType == ODT_LISTBOX) drawHistoryItem(window, item);
        else drawControl(window, item);
        return TRUE;
    }
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORLISTBOX: {
        // Edits and the read-only transcript sit on painted fields; the
        // History list and drop-downs on the window's surface.
        const auto &palette = jsti::chrome::palette();
        HDC dc = reinterpret_cast<HDC>(wparam);
        const int identifier = GetDlgCtrlID(reinterpret_cast<HWND>(lparam));
        COLORREF surface = message == WM_CTLCOLORLISTBOX && identifier == historyID ? palette.window : palette.field;
        if (identifier == backupAudioID || identifier == backupProfilesID) surface = palette.card;
        if (identifier == settingsResultsID) {
            if (highContrast()) {
                SetTextColor(dc, GetSysColor(COLOR_WINDOWTEXT));
                SetBkColor(dc, GetSysColor(COLOR_WINDOW));
                return reinterpret_cast<LRESULT>(GetSysColorBrush(COLOR_WINDOW));
            }
            surface = palette.sidebar;
        }
        SetTextColor(dc, palette.text);
        SetBkColor(dc, surface);
        return reinterpret_cast<LRESULT>(brushFor(surface));
    }
    case WM_SETTINGCHANGE:
        if (lparam && jsti::chrome::appearance() == 0 &&
            wcscmp(reinterpret_cast<const wchar_t *>(lparam), L"ImmersiveColorSet") == 0) applyTheme(window);
        break;
    case guideMessage: jsti_show_guide(window); return 0;
    case permissionsMessage: jsti_show_permissions(window); return 0;
    case profilesMessage:
        if (idleControl(window, profilesID) && IsWindowEnabled(window)) jsti_show_profiles(window);
        else jsti_cancel_profiles_request();
        return 0;
    case apiKeysMessage:
        if (idleControl(window, apiKeysID) && IsWindowEnabled(window)) jsti_show_api_keys(window);
        return 0;
    case updateMessage:
        applyUpdate(window); return 0;
    case jsti::globalEscape::message:
        if (jsti::globalEscape::take(window, wparam)) {
            const int recording = jsti_window_recording_state();
            if (recording == 1 || recording == 2) {
                retireCleanupPreview();
                const auto token = std::to_string(static_cast<uint64_t>(wparam));
                emit(window, JSTI_EVENT_CANCEL_TRANSCRIPTION, token.c_str());
            }
        }
        return 0;
    case audioCleanupMessage: {
        std::string token;
        size_t count;
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            takeAudioCleanup(token, count);
        }
        if (token.empty()) return 0;
        bool confirmed = false;
        if (idleControl(window, audioCleanupID) && IsWindowEnabled(window)) {
            const std::wstring body = L"Permanently delete " + std::to_wstring(count) +
                L" saved audio file(s), including audio kept after deleting History entries?\n\n"
                L"History entries and transcripts will be kept. Recordings saved after this "
                L"confirmation will not be deleted. This cannot be undone.";
            confirmed = MessageBoxW(window, body.c_str(), L"Delete saved recordings?",
                MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) == IDYES;
        }
        if (state.callback) state.callback(JSTI_EVENT_AUDIO_CLEANUP_RESPONSE, token.c_str(),
            confirmed ? 1 : 0, state.context);
        return 0;
    }
    case jsti::migrationRestore::message:
        jsti::migrationRestore::present(window, idleControl(window, backupRestoreID) && IsWindowEnabled(window),
            state.callback, state.context);
        return 0;
    case WM_HOTKEY:
        jsti_hotkey_message(window, message, wparam);
        return 0;
    case WM_TIMER:
        if (wparam == tourTimerID) { KillTimer(window, tourTimerID); tourStep(window); return 0; }
        if (wparam == announceTimerID) {
            KillTimer(window, announceTimerID);
            if (!jsti::hud::visible())
                jsti::accessibility::announce(GetDlgItem(window, statusID), controlText(GetDlgItem(window, statusID)), false);
            return 0;
        }
        if (jsti_hotkey_message(window, message, wparam)) return 0;
        break;
    case tourMessage: {
        std::unique_ptr<std::wstring> directory(reinterpret_cast<std::wstring *>(lparam));
        if (directory) tourBegin(window, *directory);
        return 0;
    }
    case appearanceMessage:
        SendDlgItemMessageW(window, appearanceID, CB_SETCURSEL, jsti::chrome::appearance(), 0);
        applyTheme(window);
        return 0;
    case pageMessage:
        showPage(window, static_cast<int>(wparam));
        if (takeSettingsSearchFocusPage()) SetFocus(GetDlgItem(window, navBaseID + state.page));
        return 0;
    case settingsSearchMessage:
        applySettingsResults(window);
        return 0;
    case settingsLeaveMessage:
        leaveSettingsSearch(window);
        return 0;
    case revealFieldMessage:
        // Search reveals a preference only where the Preferences button would open.
        if (idleControl(window, configurationID) && IsWindowEnabled(window))
            jsti_show_configuration_field(window, static_cast<size_t>(wparam));
        else SetDlgItemTextW(window, statusID, L"Finish the recording or close the open dialog, then search again.");
        return 0;
    case sidebarMessage: {
        std::unique_ptr<SidebarBindings> bindings;
        { std::lock_guard<std::mutex> lock(state.mutex); bindings = state.sidebarDelivery.claim(wparam); }
        if (bindings) { state.sidebar = std::move(*bindings); applySidebarBindings(window); }
        return 0;
    }
    case densityMessage: {
        std::unique_ptr<JSTIVisualDensity> density;
        { std::lock_guard<std::mutex> lock(state.mutex); density = state.densityDelivery.claim(wparam); }
        if (density) applyVisualDensity(window, *density);
        return 0;
    }
    case shellMessage: {
        std::unique_ptr<ShellPresentation> update;
        { std::lock_guard<std::mutex> lock(state.mutex); update = state.shellDelivery.claim(wparam); }
        if (update) {
            setShellPresentation(*update);
            applyShell(window);
            // Removing the icon must not strand a window hidden in the notification area.
            if (!jsti::tray::shown() && !IsWindowVisible(window)) ShowWindow(window, SW_SHOWMINNOACTIVE);
        }
        return 0;
    }
    case hudMessage:
        jsti::hud::apply();
        return 0;
    case jsti::tray::commandMessage:
        trayCommand(window, static_cast<UINT>(wparam));
        return 0;
    case WM_COMMAND:
        if (LOWORD(wparam) >= aboutLinkBaseID && LOWORD(wparam) < aboutLinkBaseID + 8) {
            const size_t index = LOWORD(wparam) - aboutLinkBaseID;
            if (HIWORD(wparam) == BN_CLICKED && state.page == aboutPage && index < aboutState().aboutLinks.size()) {
                const auto result = reinterpret_cast<INT_PTR>(
                    ShellExecuteW(window, L"open", aboutState().aboutLinks[index].url.c_str(), nullptr, nullptr, SW_SHOWNORMAL)
                );
                if (result <= 32) showFailure(window, "Could not open your browser. Check your default browser settings.");
            }
            return 0;
        }
        if (LOWORD(wparam) >= navBaseID && LOWORD(wparam) < navBaseID + pageCount) {
            if (HIWORD(wparam) == BN_CLICKED) showPage(window, LOWORD(wparam) - navBaseID);
            return 0;
        }
        switch (LOWORD(wparam)) {
        case historyCorrectionsID:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, historyCorrectionsID))) {
                const std::string record = selectedHistory(window);
                if (!record.empty()) jsti_show_vocabulary_result(window, record.c_str(),
                    [](int event, const char *payload, int kind) {
                        if (state.callback) state.callback(event, payload, kind, state.context);
                    });
            }
            return 0;
        case correctionsID: case pronunciationID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, LOWORD(wparam))) {
                jsti_show_vocabulary(window, LOWORD(wparam) == correctionsID ? 0 : 1,
                    [](int event, const char *payload, int kind) {
                        if (state.callback) state.callback(event, payload, kind, state.context);
                    });
            }
            return 0;
        case profilesID:
            if (idleControl(window, profilesID)) emit(window, 17);
            return 0;
        case comparisonID:
            if (idleControl(window, comparisonID)) jsti_show_comparison(window, state.callback, state.context);
            return 0;
        case recordID: emitRecording(window); return 0;
        case importID:
            if (idleControl(window, importID) && !liveSelection(window)) importAudio(window);
            return 0;
        case copyID: {
            if (!IsWindowEnabled(GetDlgItem(window, copyID))) return 0;
            const std::string id = selectedHistory(window);
            emit(window, JSTI_EVENT_COPY_TRANSCRIPT, id.c_str());
            return 0;
        }
        case processingID: jsti_show_postprocessing(window); return 0;
        case configurationID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, configurationID) && IsWindowEnabled(window))
                jsti_show_configuration(window, state.page == transcriptionPage ? L"Transcription" :
                    state.page == postProcessingPage ? L"Post-processing" :
                    state.page == correctionsPage ? L"Corrections" :
                    state.page == keyboardPage ? L"Keyboard" : L"General");
            return 0;
        case azureID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, azureID) && IsWindowEnabled(window)) {
                jsti_show_azure_resource_settings(window);
            }
            return 0;
        case apiKeysID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, apiKeysID) && IsWindowEnabled(window)) {
                jsti_show_api_keys(window);
            }
            return 0;
        case cloudSyncID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, cloudSyncID) && IsWindowEnabled(window)) {
                jsti_show_cloud_sync_settings(window);
            }
            return 0;
        case automationSettingsID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, automationSettingsID) && IsWindowEnabled(window)) {
                jsti_show_automation_settings(window, automationShownEnabled, requestAutomationToggle);
            }
            return 0;
        case systemResourcesID:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(window)) {
                jsti_show_system_resources(window, [](HWND owner, int event, const char *text) {
                    emit(owner, event, text ? text : "");
                });
            }
            return 0;
        case rawConfigurationID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, rawConfigurationID) && IsWindowEnabled(window)) {
                jsti_show_raw_configuration(window, [](HWND, int action, const char *text) {
                    if (state.callback) state.callback(JSTI_EVENT_RAW_CONFIGURATION, text ? text : "", action,
                                                       state.context);
                });
            }
            return 0;
        case automationID: {
            if (HIWORD(wparam) != BN_CLICKED) return 0;
            emit(window, JSTI_EVENT_AUTOMATION_TOGGLED, automationShownEnabled() ? "0" : "1");
            return 0;
        }
        case loginItemID: {
            if (HIWORD(wparam) != BN_CLICKED) return 0;
            bool requested;
            if (!claimLoginItemToggle(requested)) return 0;
            // Shows the choice at once; the host's answer settles it.
            HWND toggle = GetDlgItem(window, loginItemID);
            SetWindowLongPtrW(toggle, GWLP_USERDATA, requested ? 1 : 0);
            InvalidateRect(toggle, nullptr, FALSE);
            emit(window, JSTI_EVENT_LOGIN_ITEM, requested ? "1" : "0");
            return 0;
        }
        case recordingsFolderID:
            if (HIWORD(wparam) == BN_CLICKED) emit(window, JSTI_EVENT_RECORDINGS_FOLDER, "");
            return 0;
        case audioCleanupID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, audioCleanupID)) {
                emit(window, JSTI_EVENT_AUDIO_CLEANUP, "");
            }
            return 0;
        case backupExportID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, backupExportID)) exportMigrationBackup(window);
            return 0;
        case backupInspectID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, backupInspectID)) inspectMigrationBackup(window);
            return 0;
        case setupGuideID: if (HIWORD(wparam) == BN_CLICKED) jsti_show_guide(window); return 0;
        case permissionsID: if (HIWORD(wparam) == BN_CLICKED) jsti_show_permissions(window); return 0;
        case troubleshootingID: if (HIWORD(wparam) == BN_CLICKED) jsti_show_troubleshooting(window); return 0;
        case backupRestoreID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, backupRestoreID)) {
                std::string failure;
                const std::string selected = jsti::migrationRestore::choose(window, failure);
                if (!failure.empty()) showFailure(window, failure);
                else if (!selected.empty()) emit(window, JSTI_EVENT_MIGRATION_RESTORE, selected.c_str());
            }
            return 0;
        case appearanceID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                const LRESULT chosen = SendDlgItemMessageW(window, appearanceID, CB_GETCURSEL, 0, 0);
                if (chosen < 0 || chosen > 2) return 0;
                jsti::chrome::setAppearance(static_cast<int>(chosen));
                applyTheme(window);
                const char value[2] = {static_cast<char>('0' + chosen), 0};
                emit(window, JSTI_EVENT_APPEARANCE, value);
            }
            return 0;
        case textOutputID:
            // Only while idle and not already behind another modal editor.
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, textOutputID) && IsWindowEnabled(window)) {
                jsti_show_text_output(window);
                refreshSetup(window);
            }
            return 0;
        case shortcutID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, shortcutID) && IsWindowEnabled(window)) {
                jsti_show_hotkey_settings(window);
                applySidebarBindings(window);
                SetDlgItemTextW(window, transcriptLabelID, jsti_hotkey_label().c_str());
                refreshSetup(window);
            }
            return 0;
        case actionShortcutsID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, actionShortcutsID) && IsWindowEnabled(window)) {
                jsti_show_action_shortcuts(window);
            }
            return 0;
        case issueReportID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, issueReportID) &&
                historyView().historyPresentationReady) emitHistory(window, JSTI_EVENT_HISTORY_ISSUE_REPORT);
            return 0;
        case retryID: emitHistory(window, JSTI_EVENT_HISTORY_RETRY); return 0;
        case exportID:
            if (IsWindowEnabled(GetDlgItem(window, exportID))) emitHistory(window, JSTI_EVENT_HISTORY_EXPORT);
            return 0;
        case openAudioID: emitHistory(window, JSTI_EVENT_HISTORY_OPEN_AUDIO); return 0;
        case readAloudID:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, readAloudID))) {
                emitHistory(window, JSTI_EVENT_HISTORY_READ_ALOUD);
            }
            return 0;
        case voiceSettingsID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, voiceSettingsID) && IsWindowEnabled(window)) {
                jsti_show_voice_settings(window);
            }
            return 0;
        case voiceSourcesID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, voiceSourcesID) && IsWindowEnabled(window)) {
                const std::string transcript = historyView().historyPresentationReady
                    ? jsti::utf8(controlText(GetDlgItem(window, transcriptID))) : "";
                const std::string record = historyView().historyPresentationReady ? selectedHistoryRecord() : "";
                jsti_show_voice_sources(window, record.c_str(), transcript.c_str());
            }
            return 0;
        case voiceCredentialID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, voiceCredentialID) && IsWindowEnabled(window)) {
                jsti_show_voice_credentials(window);
            }
            return 0;
        case playPauseID:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, playPauseID))) {
                emitHistory(window, JSTI_EVENT_HISTORY_PLAY_PAUSE);
            }
            return 0;
        case stopPlaybackID:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, stopPlaybackID))) {
                if (state.page == voicePage) jsti_voice_sources_stop();
                else emitHistory(window, JSTI_EVENT_HISTORY_STOP);
            }
            return 0;
        case historyID:
            if (HIWORD(wparam) == LBN_SELCHANGE) {
                retireCleanupPreview();
                int recording;
                std::string nowSelected;
                {
                    std::lock_guard<std::mutex> lock(state.mutex);
                    nowSelected = selectedHistory(window);
                    setSelectedHistoryRecord(nowSelected);
                    noteHistoryInteraction();
                    recording = state.recording;
                }
                invalidateHistoryPresentation(window, true);
                applyVariant(window, -1, false, recording);
                applyPlayback(window, playbackIdle, L"", !nowSelected.empty(), recording);
                updateHistoryControls(window, recording);
                emitHistory(window, JSTI_EVENT_HISTORY_SELECTED);
            }
            return 0;
        case searchID:
            if (HIWORD(wparam) == EN_CHANGE) searchChanged(window);
            return 0;
        case settingsSearchID:
            if (HIWORD(wparam) == EN_CHANGE || (HIWORD(wparam) == EN_SETFOCUS && !settingsSearchSuppressed()))
                emitSettingsSearch(window);
            else if (HIWORD(wparam) == EN_KILLFOCUS) PostMessageW(window, settingsLeaveMessage, 0, 0);
            return 0;
        case settingsResultsID:
            if (HIWORD(wparam) == LBN_KILLFOCUS) PostMessageW(window, settingsLeaveMessage, 0, 0);
            return 0;
        case clearSearchID:
            if (idleControl(window, clearSearchID)) clearSearch(window);
            return 0;
        case historyFiltersID:
            if (idleControl(window, historyFiltersID)) {
                jsti_show_history_filters(window, [window](const std::string &value) {
                    emit(window, JSTI_EVENT_HISTORY_FILTERS, value.c_str());
                });
            }
            return 0;
        case historyDeleteID: {
            if (!idleControl(window, historyDeleteID)) return 0;
            const LRESULT selected = SendDlgItemMessageW(window, historyID, LB_GETCURSEL, 0, 0);
            if (selected == LB_ERR || static_cast<size_t>(selected) >= historyView().displayedHistory.size()) return 0;
            const std::string id = historyView().displayedHistory[static_cast<size_t>(selected)].id;
            const int answer = MessageBoxW(window,
                L"Delete this History entry? Its saved recording file will be kept.\n\n"
                L"This cannot be undone. If History sync is enabled, its synced text will also be deleted.",
                L"Delete History entry", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
            if (answer == IDYES && state.callback) {
                state.callback(JSTI_EVENT_HISTORY_DELETE, id.c_str(), 0, state.context);
            }
            return 0;
        }
        case historyClearID: {
            if (!idleControl(window, historyClearID)) return 0;
            const std::string ids = historyManagementIDs();
            if (ids.empty()) return 0;
            const size_t count = 1 + static_cast<size_t>(std::count(ids.begin(), ids.end(), '\n'));
            const std::wstring prompt = L"Clear all " + std::to_wstring(count)
                + L" History entries, including hidden and filtered entries?\n\n"
                L"Yes: delete History and its owned recording files.\n"
                L"No: delete History but keep recording files.\nCancel: keep everything.\n\n"
                L"This cannot be undone. If History sync is enabled, synced text will also be deleted.";
            const int answer = MessageBoxW(window, prompt.c_str(), L"Clear History",
                MB_YESNOCANCEL | MB_ICONWARNING | MB_DEFBUTTON3);
            if ((answer == IDYES || answer == IDNO) && state.callback) {
                state.callback(JSTI_EVENT_HISTORY_DELETE, ids.c_str(), answer == IDYES ? 1 : 0, state.context);
            }
            return 0;
        }
        case IDCANCEL:
            // Escape inside the search box is a keyboard clear affordance.
            if (GetFocus() == GetDlgItem(window, searchID) && idleControl(window, searchID)) clearSearch(window);
            return 0;
        case variantID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                const LRESULT chosen = SendDlgItemMessageW(window, variantID, CB_GETCURSEL, 0, 0);
                if (!idleControl(window, variantID) || !historyView().variantSwitchable || (chosen != 0 && chosen != 1)) {
                    SendDlgItemMessageW(window, variantID, CB_SETCURSEL, historyView().displayedVariant < 0
                        ? static_cast<WPARAM>(-1) : static_cast<WPARAM>(historyView().displayedVariant), 0);
                    return 0;
                }
                retireCleanupPreview();
                { std::lock_guard<std::mutex> lock(state.mutex); noteHistoryInteraction(); }
                historyView().displayedVariant = static_cast<int>(chosen);
                historyView().requestedVariant = historyView().displayedVariant;
                invalidateHistoryPresentation(window, false);
                emitHistory(window, JSTI_EVENT_TRANSCRIPT_VARIANT);
            }
            return 0;
        case microphoneID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                if (!idleControl(window, microphoneID)) { populateMicrophones(window); return 0; }
                const std::string device = selectedMicrophone(window);
                modelsState().microphoneSelection = device;
                emit(window, JSTI_EVENT_MICROPHONE_CHANGED, device.c_str());
                refreshSetup(window);
            }
            return 0;
        case modelRefreshID:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, modelRefreshID))) {
                emit(window, JSTI_EVENT_REFRESH_MODELS);
            }
            return 0;
        case modelID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                if (!idleControl(window, modelID)) {
                    const auto previous = std::find(modelsState().filteredModels.begin(), modelsState().filteredModels.end(),
                                                     modelsState().preferredModels[modelsState().activeMode]);
                    if (previous != modelsState().filteredModels.end()) SendDlgItemMessageW(window, modelID, CB_SETCURSEL,
                        static_cast<WPARAM>(previous - modelsState().filteredModels.begin()), 0);
                    return 0;
                }
                const int selected = selection(window);
                if (selected < 0) return 0;
                modelsState().preferredModels[modelsState().activeMode] = selected;
                SetDlgItemTextW(window, keyID, L"");
                emit(window, JSTI_EVENT_MODEL_CHANGED);
                refreshSetup(window);
            }
            return 0;
        case localModelsID:
            if (HIWORD(wparam) == BN_CLICKED && idleControl(window, localModelsID) && IsWindowEnabled(window)) {
                jsti_show_local_models(window);
            }
            return 0;
        case sourceID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                const LRESULT source = SendDlgItemMessageW(window, sourceID, CB_GETCURSEL, 0, 0);
                if (!idleControl(window, sourceID) || (source != 0 && source != 1) || source == activeSource()) {
                    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, activeSource(), 0);
                    return 0;
                }
                // Keep Batch or Live when the other source offers it.
                const int same = static_cast<int>(source) * 2 + modelsState().activeMode % 2;
                const int other = static_cast<int>(source) * 2 + (1 - modelsState().activeMode % 2);
                const int mode = modelsState().preferredModels[same] >= 0 ? same : other;
                if (modelsState().preferredModels[mode] < 0) {
                    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, activeSource(), 0);
                    return 0;
                }
                modelsState().activeMode = mode;
                if (!populateModels(window)) { showFailure(window, "Windows could not display this source's models."); return 0; }
                SetDlgItemTextW(window, keyID, L"");
                emit(window, JSTI_EVENT_MODEL_CHANGED);
                refreshSetup(window);
            }
            return 0;
        case modeID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                if (!idleControl(window, modeID)) {
                    SendDlgItemMessageW(window, modeID, CB_SETCURSEL, modelsState().activeMode % 2, 0);
                    return 0;
                }
                const LRESULT choice = SendDlgItemMessageW(window, modeID, CB_GETCURSEL, 0, 0);
                if (choice != 0 && choice != 1) return 0;
                const int mode = activeSource() * 2 + static_cast<int>(choice);
                if (modelsState().preferredModels[mode] < 0) return 0;
                modelsState().activeMode = mode;
                if (!populateModels(window)) { showFailure(window, "Windows could not display this mode's models."); return 0; }
                SetDlgItemTextW(window, keyID, L"");
                emit(window, JSTI_EVENT_MODEL_CHANGED);
                refreshSetup(window);
            }
            return 0;
        case saveID: {
            const int count = GetWindowTextLengthW(GetDlgItem(window, keyID));
            if (count <= 0) { showFailure(window, "Enter an API key before saving."); return 0; }
            std::wstring secret(static_cast<size_t>(count) + 1, 0);
            GetDlgItemTextW(window, keyID, &secret[0], count + 1);
            secret.resize(count);
            std::string text = jsti::utf8(secret);
            emit(window, JSTI_EVENT_SAVE_CREDENTIAL, text.c_str());
            SetDlgItemTextW(window, keyID, L"");
            SecureZeroMemory(&secret[0], secret.size() * sizeof(wchar_t));
            if (!text.empty()) SecureZeroMemory(&text[0], text.size());
            return 0;
        }
        }
        break;
    case WM_CLOSE:
        jsti_issue_report_shutdown();
        jsti::globalEscape::publish(0);
        retireCleanupPreview();
        emit(window, JSTI_EVENT_CLOSING);
        DestroyWindow(window); return 0;
    case WM_DESTROY:
        jsti_issue_report_shutdown();
        retireCleanupPreview();
        {
            std::string failure;
            if (!jsti::globalEscape::stop(failure) && !failure.empty()) showFailure(window, failure);
        }
        stopHandsFreeGuard(window);
        jsti::tray::remove();
        releaseBackdrop();
        jsti_hotkey_stop(window);
        jsti_action_shortcuts_stop();
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.window = nullptr; state.posted = false; retireHousekeeping();
            state.sidebarDelivery.retire();
            state.densityDelivery.retire();
            state.shellDelivery.retire();
        }
        retireSettingsSearch();
        jsti::migrationRestore::clear();
        PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
} // namespace jsti_window
