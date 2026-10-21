#pragma once
#include "WindowsSupportInternal.hpp"

namespace jsti::globalEscape {
constexpr UINT message = WM_APP + 110;
using Failure = void (*)(HWND, const std::string &);

// Publish every state transition, even when native presentation is coalesced.
void publish(int recording);
void configure(bool enabled);
void editing(bool active);
bool enabled();
uint64_t token();
// UI thread only. Synthetic windows must pass enabled=false.
bool reconcile(HWND window, bool enabled, Failure report, std::string &failure);
bool take(HWND window, WPARAM token);
// Thread-safe final admission check for the Host actor.
bool current(uint64_t token);
bool stop(std::string &failure);
bool selfTest(HWND window, std::string &failure);
}
