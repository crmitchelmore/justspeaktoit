#pragma once

#include "WindowsSupportInternal.hpp"

// Cloud sharing consent (CloudSharing.h), owned by WindowsCloudSharing.cpp.
// Both run a modal loop on the UI thread over `owner` and report through `callback`.

// Shows the staged first-use question. Reports JSTI_EVENT_CLOUD_CONSENT_RESPONSE once; closing is "not now".
void jsti_present_cloud_sharing_request(HWND owner, JSTIWindowCallback callback, void *context);
// The allowed providers, each with a Withdraw button (About > Privacy settings).
void jsti_show_cloud_sharing(HWND owner, JSTIWindowCallback callback, void *context);
