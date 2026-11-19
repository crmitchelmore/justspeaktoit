// The per-target UI Automation worker: capture, selection read, insertion, paste fallback and learning.
#include "WindowsTextOutputParts.hpp"

namespace jsti::textoutput {
bool deliveryOwnerAvailable(const State &state, std::string &error) {
    if (!state.requiresDeliveryOwner) return true;
    const auto owner = state.deliveryOwner.lock();
    if (!owner || WaitForSingleObject(owner->process.value, 0) != WAIT_TIMEOUT) {
        error = "The original application process has exited."; return false;
    }
    if (!verifyIdentity(owner->environment, owner->identity, error, true)) return false;
    const NativeKind kind = classifyNative(owner->identity.focus);
    if (kind == NativeKind::Password || kind == NativeKind::ReadOnly || kind == NativeKind::Disabled) {
        error = refusal(kind); return false;
    }
    std::lock_guard<std::mutex> lock(owner->mutex);
    if (owner->abandoned || owner->shutdown) { error = "This insertion target was cancelled."; return false; }
    return true;
}

namespace {

class Worker {
    std::shared_ptr<State> state;
    Ref<IUIAutomation> automation;
    Ref<IUIAutomationElement> captured;
    Ref<IUIAutomationTextRange> learningRange;
    Ref<IUIAutomationTextRange> voiceEditRange;
    std::wstring voiceEditText, voiceEditDocument, voiceEditPrefix, voiceEditSuffix;
    std::wstring learningBefore, learningAfter;
    bool learningAtStart = false, learningAtEnd = false;

    bool rangeText(IUIAutomationTextRange *range, int limit, std::wstring &value) {
        BStr text;
        if (!range || FAILED(range->GetText(limit + 1, &text.value))) return false;
        value = text.str();
        return value.size() <= static_cast<size_t>(limit);
    }

    bool learningContext(std::wstring &before, std::wstring &after, bool &atStart, bool &atEnd) {
        Patterns patterns;
        fetchPatterns(captured.value, patterns);
        if (!patterns.text) return false;
        Ref<IUIAutomationTextRange> document, left, right;
        if (FAILED(patterns.text->get_DocumentRange(document.put())) || !document ||
            FAILED(learningRange->Clone(left.put())) || FAILED(learningRange->Clone(right.put())) ||
            !left || !right) return false;
        int start = 0, end = 0, moved = 0;
        if (FAILED(learningRange->CompareEndpoints(TextPatternRangeEndpoint_Start, document.value,
                TextPatternRangeEndpoint_Start, &start)) ||
            FAILED(learningRange->CompareEndpoints(TextPatternRangeEndpoint_End, document.value,
                TextPatternRangeEndpoint_End, &end))) return false;
        atStart = start == 0; atEnd = end == 0;
        if (FAILED(left->MoveEndpointByRange(TextPatternRangeEndpoint_End, learningRange.value,
                TextPatternRangeEndpoint_Start)) ||
            FAILED(left->MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -32, &moved)) ||
            FAILED(right->MoveEndpointByRange(TextPatternRangeEndpoint_Start, learningRange.value,
                TextPatternRangeEndpoint_End)) ||
            FAILED(right->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, 32, &moved))) return false;
        return rangeText(left.value, 256, before) && rangeText(right.value, 256, after);
    }

    bool sampleLearning(bool capture, const std::wstring &original, std::wstring &edited, std::string &error) {
        error = "Correction learning skipped: the original field/range is unavailable or its ownership changed.";
        const NativeKind kind = classifyNative(state->identity.focus);
        if (kind == NativeKind::Password || kind == NativeKind::ReadOnly || kind == NativeKind::Disabled) {
            error = refusal(kind);
            return false;
        }
        if (abandoned() || WaitForSingleObject(state->process.value, 0) != WAIT_TIMEOUT || !verifyField(error)) return false;
        if (capture) {
            Patterns patterns;
            fetchPatterns(captured.value, patterns);
            Ref<IUIAutomationTextRangeArray> selection;
            int count = 0, comparison = 0, moved = 0;
            bool wholeField = false;
            DWORD acknowledgedCaret = static_cast<DWORD>(-1);
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                wholeField = state->learningWholeField;
                acknowledgedCaret = state->learningCaret;
            }
            if (!patterns.text) return false;
            if (wholeField) {
                if (FAILED(patterns.text->get_DocumentRange(learningRange.put())) || !learningRange) return false;
            } else {
                DWORD start = 0, end = 0;
                DWORD_PTR ignored = 0;
                if (acknowledgedCaret == static_cast<DWORD>(-1) ||
                    !SendMessageTimeoutW(state->identity.focus, EM_GETSEL, reinterpret_cast<WPARAM>(&start),
                        reinterpret_cast<LPARAM>(&end), SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT,
                        1000, &ignored) || start != acknowledgedCaret || end != acknowledgedCaret ||
                    FAILED(patterns.text->GetSelection(selection.put())) || !selection ||
                FAILED(selection->get_Length(&count)) || count != 1 ||
                FAILED(selection->GetElement(0, learningRange.put())) || !learningRange ||
                FAILED(learningRange->CompareEndpoints(TextPatternRangeEndpoint_Start, learningRange.value,
                    TextPatternRangeEndpoint_End, &comparison)) || comparison != 0 ||
                FAILED(learningRange->MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character,
                    -static_cast<int>(original.size()), &moved))) return false;
            }
            if (!rangeText(learningRange.value, 8192, edited) || edited != original ||
                !learningContext(learningBefore, learningAfter, learningAtStart, learningAtEnd)) {
                learningRange.reset();
                return false;
            }
        } else {
            std::wstring before, after;
            bool atStart = false, atEnd = false;
            if (!learningRange || !learningContext(before, after, atStart, atEnd) ||
                before != learningBefore || after != learningAfter ||
                atStart != learningAtStart || atEnd != learningAtEnd ||
                !rangeText(learningRange.value, 8192, edited)) return false;
            learningRange.reset(); // One observation, never a whole-field watcher.
        }
        const NativeKind finalKind = classifyNative(state->identity.focus);
        if (finalKind == NativeKind::Password || finalKind == NativeKind::ReadOnly || finalKind == NativeKind::Disabled) {
            error = refusal(finalKind);
            return false;
        }
        return !abandoned() && verifyField(error);
    }

    bool abandoned() {
        std::lock_guard<std::mutex> lock(state->mutex);
        return state->abandoned || state->shutdown;
    }

    bool focusUnchanged() {
        return state->focusRevision != 0 && state->environment.focusRevision &&
            state->environment.focusRevision() == state->focusRevision;
    }

    bool verifyField(std::string &error) {
        if (!focusUnchanged() || !captured) { error = changedMessage; return false; }
        if (!verifyIdentity(state->environment, state->identity, error)) return false;
        Ref<IUIAutomationElement> current;
        BOOL same = FALSE;
        if (FAILED(state->environment.focusedElement(automation.value, state->identity.focus, current.put())) || !current ||
            FAILED(automation->CompareElements(captured.value, current.value, &same)) || !same) {
            error = changedMessage;
            return false;
        }
        Patterns patterns;
        fetchPatterns(current.value, patterns);
        const Facts facts = inspect(current.value, patterns);
        if (!editable(facts, patterns)) { error = unsupportedMessage; return false; }
        return true;
    }

    bool beginMutation(const JSTIInsertionResult &result, std::string &error) {
        if (state->voiceEditTarget && !verifyVoiceEditAnchor(error)) return false;
        if (!deliveryOwnerAvailable(*state, error)) return false;
        if (WaitForSingleObject(state->process.value, 0) != WAIT_TIMEOUT) {
            error = "The original application process has exited."; return false;
        }
        if (!focusUnchanged() || !verifyIdentity(state->environment, state->identity, error)) {
            error = changedMessage;
            return false;
        }
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->abandoned || state->shutdown) { error = timeoutMessage; return false; }
        state->mutationStarted = true;
        state->result = result;
        return true;
    }

    void createAutomation() {
        const Environment &environment = state->environment;
        Ref<IUIAutomation2> modern;
        if (SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_IUIAutomation2,
                                       reinterpret_cast<void **>(modern.put()))) && modern) {
            // Bound every provider round trip so a hung application cannot
            // hold the worker beyond the caller's timeout by much.
            modern->put_ConnectionTimeout(environment.providerTimeoutMs);
            modern->put_TransactionTimeout(environment.providerTimeoutMs);
            modern->QueryInterface(IID_IUIAutomation, reinterpret_cast<void **>(automation.put()));
        } else {
            CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_IUIAutomation,
                             reinterpret_cast<void **>(automation.put()));
        }
    }

    // Background capture is usable only if no focus transition occurred while
    // the provider was resolving it. Failure never downgrades a virtual field
    // to HWND-only identity.
    void captureFocus() {
        if (!automation || !focusUnchanged() || !state->focusEvent.window || !state->environment.resolveFocusEvent) return;
        Ref<IUIAutomationElement> element;
        if (FAILED(state->environment.resolveFocusEvent(automation.value, state->focusEvent, element.put())) || !element) return;
        if (focusUnchanged() && elementBelongs(automation.value, element.value, state->identity)) captured.retain(element.value);
    }

    bool verifySelectionElement(std::string &error) {
        if (abandoned()) { error = "Selected-text capture was cancelled."; return false; }
        if (GetTickCount64() >= state->selectionDeadline) {
            error = "Selected-text capture timed out."; return false;
        }
        if (WaitForSingleObject(state->process.value, 0) != WAIT_TIMEOUT) {
            error = "The original application process has exited."; return false;
        }
        if (!focusUnchanged() || !verifyIdentity(state->environment, state->identity, error)) {
            error = changedMessage; return false;
        }
        const NativeKind kind = classifyNative(state->identity.focus);
        if (kind == NativeKind::Password || kind == NativeKind::Disabled) {
            error = refusal(kind); return false;
        }
        Ref<IUIAutomationElement> current;
        if (!automation || !state->environment.focusedElement ||
            FAILED(state->environment.focusedElement(automation.value, state->identity.focus, current.put())) ||
            !current || !elementBelongs(automation.value, current.value, state->identity)) {
            error = "The original app does not expose a readable text selection."; return false;
        }
        if (captured) {
            BOOL same = FALSE;
            if (FAILED(automation->CompareElements(captured.value, current.value, &same)) || !same) {
                error = changedMessage; return false;
            }
        } else {
            captured.retain(current.value);
        }
        BOOL password = TRUE, enabled = FALSE;
        if (FAILED(current->get_CurrentIsPassword(&password)) || password ||
            FAILED(current->get_CurrentIsEnabled(&enabled)) || !enabled) {
            error = "Password, disabled or unidentified fields cannot be read aloud."; return false;
        }
        if (abandoned() || !focusUnchanged() ||
            !verifyIdentity(state->environment, state->identity, error)) {
            error = "Selected-text capture was cancelled or its focus changed."; return false;
        }
        return true;
    }

    bool sampleSelection(std::wstring &text, std::string &error) {
        if (!verifySelectionElement(error)) return false;
        Patterns patterns;
        fetchPatterns(captured.value, patterns);
        Ref<IUIAutomationTextRangeArray> ranges;
        int count = 0;
        if (!patterns.text || FAILED(patterns.text->GetSelection(ranges.put())) || !ranges ||
            FAILED(ranges->get_Length(&count)) || count < 1 || count > 64) {
            error = "The original app does not expose a bounded text selection."; return false;
        }
        if (state->voiceEditTarget && (count != 1 || !editable(inspect(captured.value, patterns), patterns))) {
            error = "Voice editing requires one editable text selection."; return false;
        }
        for (int index = 0; index < count; ++index) {
            if (abandoned() || GetTickCount64() >= state->selectionDeadline) {
                error = "Selected-text capture was cancelled or timed out."; return false;
            }
            Ref<IUIAutomationTextRange> range;
            std::wstring selected;
            if (text.size() > maximumSelectedTextUnits ||
                FAILED(ranges->GetElement(index, range.put())) ||
                !rangeText(range.value, static_cast<int>(maximumSelectedTextUnits - text.size()), selected) ||
                !appendSelectedRange(text, selected)) {
                error = "Selected text is unavailable or exceeds the 200,000 UTF-16-unit limit."; return false;
            }
            if (state->voiceEditTarget && (FAILED(range->Clone(voiceEditRange.put())) || !voiceEditRange)) {
                error = "The original selection could not be anchored for voice editing."; return false;
            }
        }
        if (text.empty()) { error = "There is no selected text to read aloud."; return false; }
        if (state->voiceEditTarget) {
            Ref<IUIAutomationTextRange> document, prefix, suffix;
            if (FAILED(patterns.text->get_DocumentRange(document.put())) || !document ||
                !rangeText(document.value, 2000000, voiceEditDocument) ||
                FAILED(document->Clone(prefix.put())) || !prefix ||
                FAILED(document->Clone(suffix.put())) || !suffix ||
                FAILED(prefix->MoveEndpointByRange(TextPatternRangeEndpoint_End, voiceEditRange.value,
                    TextPatternRangeEndpoint_Start)) ||
                FAILED(suffix->MoveEndpointByRange(TextPatternRangeEndpoint_Start, voiceEditRange.value,
                    TextPatternRangeEndpoint_End)) ||
                !rangeText(prefix.value, 2000000, voiceEditPrefix) ||
                !rangeText(suffix.value, 2000000, voiceEditSuffix) ||
                voiceEditPrefix + text + voiceEditSuffix != voiceEditDocument) {
                error = "The original field is unavailable or too large to verify safely."; return false;
            }
            voiceEditText = text;
            if (!verifyVoiceEditAnchor(error)) return false;
        }
        return verifySelectionElement(error);
    }

    bool verifyVoiceEditAnchor(std::string &error) {
        const NativeKind kind = classifyNative(state->identity.focus);
        if (kind == NativeKind::Password || kind == NativeKind::ReadOnly || kind == NativeKind::Disabled) {
            error = refusal(kind);
            return false;
        }
        if (!voiceEditRange || !verifyField(error)) {
            if (error.empty()) error = "The voice-edit selection was not captured.";
            return false;
        }
        Patterns patterns;
        fetchPatterns(captured.value, patterns);
        Ref<IUIAutomationTextRangeArray> ranges;
        Ref<IUIAutomationTextRange> selected, document;
        int count = 0, start = 1, end = 1;
        std::wstring text, entire;
        if (!patterns.text || FAILED(patterns.text->GetSelection(ranges.put())) || !ranges ||
            FAILED(ranges->get_Length(&count)) || count != 1 ||
            FAILED(ranges->GetElement(0, selected.put())) || !selected ||
            FAILED(selected->CompareEndpoints(TextPatternRangeEndpoint_Start, voiceEditRange.value,
                TextPatternRangeEndpoint_Start, &start)) ||
            FAILED(selected->CompareEndpoints(TextPatternRangeEndpoint_End, voiceEditRange.value,
                TextPatternRangeEndpoint_End, &end)) || start != 0 || end != 0 ||
            !rangeText(selected.value, static_cast<int>(maximumSelectedTextUnits), text) || text != voiceEditText ||
            FAILED(patterns.text->get_DocumentRange(document.put())) || !document ||
            !rangeText(document.value, 2000000, entire) || entire != voiceEditDocument) {
            error = "The captured selection or its field changed. The voice edit was not applied.";
            return false;
        }
        return !abandoned() && verifyField(error);
    }

    static std::wstring voiceEditLineEndings(const std::wstring &text) {
        std::wstring result;
        result.reserve(text.size());
        for (size_t index = 0; index < text.size(); ++index) {
            if (text[index] == L'\r') {
                result.push_back(L'\n');
                if (index + 1 < text.size() && text[index + 1] == L'\n') ++index;
            } else {
                result.push_back(text[index]);
            }
        }
        return result;
    }

    bool voiceEditApplied(const Patterns &patterns, const std::wstring &replacement) {
        Ref<IUIAutomationTextRange> document;
        std::wstring actual;
        return patterns.text && SUCCEEDED(patterns.text->get_DocumentRange(document.put())) && document &&
            rangeText(document.value, 2000000, actual) &&
            voiceEditLineEndings(actual) == voiceEditLineEndings(voiceEditPrefix + replacement + voiceEditSuffix);
    }

    int paste(const std::wstring &text, unsigned flags, const Patterns &patterns, JSTIInsertionResult &result, std::string &error) {
        const Environment &environment = state->environment;
        Clipboard &clipboard = *environment.clipboard();
        const bool keep = (flags & JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD) != 0;
        ClipboardSnapshot snapshot;
        std::wstring before;
        bool readable = false;
        readField(patterns, before, readable);
        const size_t expected = readable ? occurrences(normalizedForComparison(before), normalizedForComparison(text)) + 1 : 0;
        DWORD sequence = 0;
        {
            OwnerWindow owner;
            if (!owner.handle) { error = systemError("Creating clipboard owner", owner.error); return -1; }
            if (!placeText(clipboard, owner.handle, text, true, sequence, error, &snapshot, &result.clipboard,
                           [&] { return !abandoned(); })) return -1;
        }
        auto restore = [&]() -> int {
            if (keep) return JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT;
            OwnerWindow owner;
            return owner.handle ? restoreClipboard(clipboard, owner.handle, snapshot, sequence)
                                : JSTI_INSERTION_CLIPBOARD_RESTORE_FAILED;
        };
        // Modifier waits and all provider reads precede the final dispatch
        // guard. Cancellation/focus changes during a wait prevent the paste.
        std::string pasteError;
        if (environment.preparePaste && !environment.preparePaste(pasteError)) {
            result.clipboard = restore(); error = pasteError; return -1;
        }
        if (!verifyField(error)) { result.clipboard = restore(); return -1; }
        if (clipboard.sequence() != sequence) {
            result.clipboard = JSTI_INSERTION_CLIPBOARD_CHANGED_MEANWHILE;
            error = "The clipboard changed before paste dispatch. Copy the transcript instead.";
            return -1;
        }
        result.method = JSTI_INSERTION_METHOD_PASTE;
        result.clipboard = JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT;
        if (!beginMutation(result, error)) {
            result.method = JSTI_INSERTION_METHOD_NONE; result.clipboard = restore(); return -1;
        }
        const unsigned sent = environment.sendPaste(pasteError);
        if (sent != 4) {
            if (environment.releasePasteKeys) environment.releasePasteKeys(sent);
            error = pasteError;
            if (sent == 0) {
                result.method = JSTI_INSERTION_METHOD_NONE;
                result.clipboard = restore();
                return -1;
            }
            // Some shortcut events reached the input queue. Keep the transcript
            // available for a delayed paste; never substitute the old clipboard.
            return 1;
        }
        bool verified = false;
        if (readable || state->voiceEditTarget) {
            const ULONGLONG deadline = GetTickCount64() + environment.verifyTimeoutMs;
            while (true) {
                std::wstring after;
                bool readableNow = false;
                const bool matches = state->voiceEditTarget ? voiceEditApplied(patterns, text) :
                    (readField(patterns, after, readableNow) &&
                     occurrences(normalizedForComparison(after), normalizedForComparison(text)) >= expected);
                if (matches) { verified = true; break; }
                if (GetTickCount64() >= deadline) break;
                environment.sleep(environment.verifyIntervalMs);
            }
        }
        result.verified = verified ? 1 : 0;
        if (keep) { result.clipboard = JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT; return 0; }
        if (verified) { result.clipboard = restore(); return 0; }
        // The text could not be confirmed: the application may still be
        // processing or may have transformed it. Keep the transcript
        // available rather than risk a later paste of the old content.
        result.clipboard = JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT;
        return 0;
    }

    int insert(const std::wstring &text, unsigned flags, JSTIInsertionResult &result, std::string &error) {
        const Environment &environment = state->environment;
        result = {};
        result.method = JSTI_INSERTION_METHOD_NONE;
        result.identity = JSTI_INSERTION_IDENTITY_WINDOW;
        result.clipboard = JSTI_INSERTION_CLIPBOARD_UNTOUCHED;
        if (environment.beforeAutomation) environment.beforeAutomation(environment.hookContext);
        if (!automation) {
            error = "UI Automation is unavailable, so this application's text field cannot be verified. Copy the transcript instead.";
            return -1;
        }
        if (!verifyIdentity(environment, state->identity, error)) return -1;
        Ref<IUIAutomationElement> current;
        if (FAILED(environment.focusedElement(automation.value, state->identity.focus, current.put())) || !current) {
            error = "The focused field could not be identified through UI Automation. Copy the transcript instead.";
            return -1;
        }
        if (!elementBelongs(automation.value, current.value, state->identity)) { error = movedMessage; return -1; }
        if (!captured || !focusUnchanged()) { error = changedMessage; return -1; }
        if (captured) {
            BOOL same = FALSE;
            if (FAILED(automation->CompareElements(captured.value, current.value, &same)) || !same) {
                error = changedMessage;
                return -1;
            }
            result.identity = JSTI_INSERTION_IDENTITY_FIELD;
        }
        Patterns patterns;
        fetchPatterns(current.value, patterns);
        const Facts facts = inspect(current.value, patterns);
        if (facts.password) { error = passwordMessage; return -1; }
        if (!facts.enabled) { error = disabledMessage; return -1; }
        if (facts.readOnlyKnown && facts.readOnly) { error = readOnlyMessage; return -1; }
        if (!editable(facts, patterns)) { error = unsupportedMessage; return -1; }
        const bool replaceField = (flags & JSTI_INSERTION_REPLACE_FIELD) != 0;
        if (state->voiceEditTarget && !verifyVoiceEditAnchor(error)) return -1;
        if (state->voiceEditTarget && voiceEditPrefix.size() + text.size() + voiceEditSuffix.size() > 2000000) {
            error = "The rewritten field would exceed the voice-edit verification limit.";
            return -1;
        }
        if (patterns.value) {
            bool useValue = replaceField;
            if (!useValue) {
                BStr value;
                if (SUCCEEDED(patterns.value->get_CurrentValue(&value.value)) && (!value.value || SysStringLen(value.value) == 0)) {
                    useValue = true;
                }
            }
            if (!useValue && patterns.text && wholeDocumentSelected(patterns.text.value)) useValue = true;
            if (useValue) {
                BStr payload;
                payload.value = SysAllocStringLen(text.data(), static_cast<UINT>(text.size()));
                if (!payload.value) { error = "Could not allocate the insertion text."; return -1; }
                if (!verifyField(error)) return -1;
                result.method = JSTI_INSERTION_METHOD_UIA_VALUE;
                if (!beginMutation(result, error)) { result.method = JSTI_INSERTION_METHOD_NONE; return -1; }
                const HRESULT set = patterns.value->SetValue(payload.value);
                if (FAILED(set)) { error = automationError("Setting the field value", set); return 1; }
                result.method = JSTI_INSERTION_METHOD_UIA_VALUE;
                std::wstring after;
                bool readable = false;
                result.verified = state->voiceEditTarget ? (voiceEditApplied(patterns, text) ? 1 : 0) :
                    (readField(patterns, after, readable) && containsNormalized(after, text) ? 1 : 0);
                return 0;
            }
        } else if (replaceField) {
            error = "Replacing this field requires a UI Automation Value pattern, which it does not expose. Copy the transcript instead.";
            return -1;
        }
        if (flags & JSTI_INSERTION_NO_PASTE_FALLBACK) {
            error = "This field needs the clipboard paste fallback, which is disabled. Copy the transcript instead.";
            return -1;
        }
        return paste(text, flags, patterns, result, error);
    }

public:
    explicit Worker(std::shared_ptr<State> shared) : state(std::move(shared)) {}

    void run() {
        WorkerScope scope;
        const bool com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
        try {
        if (state->environment.beforeAutomation) state->environment.beforeAutomation(state->environment.hookContext);
        if (com && !abandoned()) {
            createAutomation();
            captureFocus();
        }
        while (true) {
            std::wstring text;
            unsigned flags = 0;
            bool learning = false, capture = false, selection = false;
            {
                std::unique_lock<std::mutex> lock(state->mutex);
                state->changed.wait(lock, [&] {
                    return state->shutdown || state->insertRequested || state->learningRequested ||
                        state->selectionRequested;
                });
                if (state->shutdown) break;
                selection = state->selectionRequested;
                learning = state->learningRequested;
                if (selection) {
                    state->selectionRequested = false;
                } else if (learning) {
                    capture = state->learningCapture;
                    state->learningRequested = false;
                    text = state->learningInserted;
                } else {
                    state->insertRequested = false;
                    text = state->text;
                    flags = state->flags;
                }
            }
            if (selection) {
                std::wstring selected;
                std::string error;
                const bool success = sampleSelection(selected, error);
                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    if (success && !state->abandoned && !state->shutdown)
                        state->selectionText = std::move(selected);
                    state->selectionError = error;
                    state->selectionStatus = success ? 0 : -1;
                    state->selectionFinished = true;
                    state->insertBusy = false;
                    state->shutdown = state->shutdown || state->abandoned || !state->voiceEditTarget || !success;
                }
                state->changed.notify_all();
                if (!success || !state->voiceEditTarget) break;
                continue;
            }
            if (learning) {
                std::wstring edited;
                std::string error;
                const bool success = sampleLearning(capture, text, edited, error);
                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    state->learningText = success ? edited : std::wstring();
                    state->learningError = error;
                    state->learningStatus = success ? 0 : -1;
                    state->learningFinished = true;
                    state->insertBusy = false;
                }
                state->changed.notify_all();
                continue;
            }
            JSTIInsertionResult result{};
            std::string error;
            const int status = insert(text, flags, result, error);
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->result = result;
                state->error = error;
                state->status = status;
                state->insertBusy = false;
                state->insertFinished = true;
                state->learningAcknowledged = status == 0 && result.verified != 0
                    && result.identity == JSTI_INSERTION_IDENTITY_FIELD
                    && result.method == JSTI_INSERTION_METHOD_UIA_VALUE;
                state->learningWholeField = state->learningAcknowledged;
                state->learningCaret = static_cast<DWORD>(-1);
                state->learningInserted = state->learningAcknowledged ? text : std::wstring();
                state->learningStarted = false;
            }
            state->changed.notify_all();
        }
        } catch (...) {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->status = state->mutationStarted ? 1 : -1;
            try { state->error = "The insertion worker could not complete the operation."; } catch (...) {}
            state->insertBusy = false;
            state->insertFinished = true;
            state->shutdown = true;
            state->changed.notify_all();
        }
        learningRange.reset();
        voiceEditRange.reset();
        captured.reset();
        automation.reset();
        if (com) CoUninitialize();
        SetEvent(state->exited.value);
    }
};

} // namespace

void runInsertionWorker(std::shared_ptr<State> state) { Worker(std::move(state)).run(); }

bool appendSelectedRange(std::wstring &text, const std::wstring &selected) {
    if (text.size() > maximumSelectedTextUnits || selected.find(L'\0') != std::wstring::npos) return false;
    if (selected.empty()) return true;
    const size_t separator = text.empty() ? 0 : 1;
    const size_t remaining = maximumSelectedTextUnits - text.size();
    if (separator > remaining || selected.size() > remaining - separator) return false;
    if (separator) text.push_back(L'\n');
    text += selected;
    return true;
}

// Line endings, whitespace runs and zero-width marks differ between what an
// application stores and what it exposes; compare the visible words only.
std::wstring normalizedForComparison(const std::wstring &text) {
    std::wstring result;
    result.reserve(text.size());
    bool pendingSpace = false;
    for (const wchar_t character : text) {
        if (character == 0x200B || character == 0x200C || character == 0x200D || character == 0xFEFF) continue;
        const bool space = character == L' ' || character == L'\t' || character == L'\r' || character == L'\n' ||
            character == 0x000B || character == 0x000C || character == 0x00A0 || character == 0x2028 || character == 0x2029;
        if (space) { pendingSpace = !result.empty(); continue; }
        if (pendingSpace) { result.push_back(L' '); pendingSpace = false; }
        result.push_back(character);
    }
    return result;
}

bool containsNormalized(const std::wstring &haystack, const std::wstring &needle) {
    const std::wstring wanted = normalizedForComparison(needle);
    return !wanted.empty() && normalizedForComparison(haystack).find(wanted) != std::wstring::npos;
}

} // namespace jsti::textoutput
