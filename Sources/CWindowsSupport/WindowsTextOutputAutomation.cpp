// UI Automation inspection of the captured element: patterns, field facts, selection and read-back.
#include "WindowsTextOutputParts.hpp"

namespace jsti::textoutput {
void fetchPatterns(IUIAutomationElement *element, Patterns &patterns) {
    Ref<IUnknown> unknown;
    if (SUCCEEDED(element->GetCurrentPattern(UIA_ValuePatternId, unknown.put())) && unknown) {
        unknown->QueryInterface(IID_IUIAutomationValuePattern, reinterpret_cast<void **>(patterns.value.put()));
    }
    if (SUCCEEDED(element->GetCurrentPattern(UIA_TextPatternId, unknown.put())) && unknown) {
        unknown->QueryInterface(IID_IUIAutomationTextPattern, reinterpret_cast<void **>(patterns.text.put()));
    }
}

Facts inspect(IUIAutomationElement *element, const Patterns &patterns) {
    Facts facts;
    element->get_CurrentControlType(&facts.type);
    BOOL flag = FALSE;
    if (SUCCEEDED(element->get_CurrentIsPassword(&flag))) { facts.passwordKnown = true; facts.password = flag != FALSE; }
    flag = TRUE;
    if (SUCCEEDED(element->get_CurrentIsEnabled(&flag))) { facts.enabledKnown = true; facts.enabled = flag != FALSE; }
    if (patterns.value) {
        flag = FALSE;
        if (SUCCEEDED(patterns.value->get_CurrentIsReadOnly(&flag))) { facts.readOnlyKnown = true; facts.readOnly = flag != FALSE; }
    }
    if (!facts.readOnlyKnown && patterns.text) {
        Ref<IUIAutomationTextRange> range;
        VARIANT value;
        VariantInit(&value);
        if (SUCCEEDED(patterns.text->get_DocumentRange(range.put())) && range &&
            SUCCEEDED(range->GetAttributeValue(UIA_IsReadOnlyAttributeId, &value)) && value.vt == VT_BOOL) {
            facts.readOnlyKnown = true;
            facts.readOnly = value.boolVal != VARIANT_FALSE;
        }
        VariantClear(&value);
    }
    return facts;
}

bool editable(const Facts &facts, const Patterns &patterns) {
    if (!facts.passwordKnown || !facts.enabledKnown || !facts.readOnlyKnown ||
        facts.password || !facts.enabled || facts.readOnly) return false;
    if (facts.type == UIA_EditControlTypeId || facts.type == UIA_DocumentControlTypeId ||
        facts.type == UIA_ComboBoxControlTypeId) return true;
    return patterns.text && patterns.value && !facts.readOnly;
}

namespace {

// The nearest ancestor with a native window handle. Browser and XAML text
// fields report no handle of their own; their host window must be the
// captured focus window.
HWND nearestWindow(IUIAutomation *automation, IUIAutomationElement *element) {
    Ref<IUIAutomationTreeWalker> walker;
    if (FAILED(automation->get_RawViewWalker(walker.put())) || !walker) return nullptr;
    Ref<IUIAutomationElement> current;
    current.retain(element);
    for (int depth = 0; depth < 64 && current; ++depth) {
        UIA_HWND handle = nullptr;
        if (SUCCEEDED(current->get_CurrentNativeWindowHandle(&handle)) && handle) return static_cast<HWND>(handle);
        Ref<IUIAutomationElement> parent;
        if (FAILED(walker->GetParentElement(current.value, parent.put())) || !parent) return nullptr;
        current.retain(parent.value);
    }
    return nullptr;
}

} // namespace

bool elementBelongs(IUIAutomation *automation, IUIAutomationElement *element, const Identity &identity) {
    int process = 0;
    if (FAILED(element->get_CurrentProcessId(&process)) || static_cast<DWORD>(process) != identity.process) return false;
    const HWND handle = nearestWindow(automation, element);
    if (!handle) return false;
    return (handle == identity.focus || IsChild(identity.focus, handle) || IsChild(handle, identity.focus)) &&
        GetAncestor(handle, GA_ROOT) == identity.window;
}

namespace {

bool selectionRange(IUIAutomationTextPattern *text, Ref<IUIAutomationTextRange> &range) {
    Ref<IUIAutomationTextRangeArray> ranges;
    if (FAILED(text->GetSelection(ranges.put())) || !ranges) return false;
    int length = 0;
    if (FAILED(ranges->get_Length(&length)) || length < 1) return false;
    return SUCCEEDED(ranges->GetElement(0, range.put())) && range;
}

} // namespace

bool wholeDocumentSelected(IUIAutomationTextPattern *text) {
    Ref<IUIAutomationTextRange> selection, document;
    if (!selectionRange(text, selection) || FAILED(text->get_DocumentRange(document.put())) || !document) return false;
    int start = 1, end = 1;
    if (FAILED(selection->CompareEndpoints(TextPatternRangeEndpoint_Start, document.value,
                                           TextPatternRangeEndpoint_Start, &start)) ||
        FAILED(selection->CompareEndpoints(TextPatternRangeEndpoint_End, document.value,
                                           TextPatternRangeEndpoint_End, &end))) return false;
    BStr content;
    const bool nonEmpty = SUCCEEDED(document->GetText(1, &content.value)) && content.value && SysStringLen(content.value) > 0;
    return nonEmpty && start == 0 && end == 0;
}

// Reads the field through the Value pattern, else the whole document text
// (bounded). readable stays false when neither is available.
bool readField(const Patterns &patterns, std::wstring &content, bool &readable) {
    readable = false;
    if (patterns.value) {
        BStr value;
        if (SUCCEEDED(patterns.value->get_CurrentValue(&value.value))) { content = value.str(); readable = true; return true; }
    }
    if (patterns.text) {
        Ref<IUIAutomationTextRange> document;
        BStr text;
        if (SUCCEEDED(patterns.text->get_DocumentRange(document.put())) && document &&
            SUCCEEDED(document->GetText(2000000, &text.value))) { content = text.str(); readable = true; return true; }
    }
    return false;
}

size_t occurrences(const std::wstring &haystack, const std::wstring &needle) {
    if (needle.empty()) return 0;
    size_t count = 0;
    for (size_t position = haystack.find(needle); position != std::wstring::npos;
         position = haystack.find(needle, position + needle.size())) ++count;
    return count;
}

std::string automationError(const char *operation, HRESULT code) {
    return std::string(operation) + " failed (HRESULT 0x" + [code] {
        char digits[16]{};
        const unsigned long value = static_cast<unsigned long>(static_cast<uint32_t>(code));
        const char *hex = "0123456789ABCDEF";
        for (int index = 7; index >= 0; --index) digits[7 - index] = hex[(value >> (index * 4)) & 0xF];
        return std::string(digits);
    }() + ").";
}

} // namespace jsti::textoutput
