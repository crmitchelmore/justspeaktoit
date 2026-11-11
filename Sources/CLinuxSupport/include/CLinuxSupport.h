#ifndef JSTI_LINUX_SUPPORT_H
#define JSTI_LINUX_SUPPORT_H

#include <stddef.h>
#include <stdint.h>
#include "LinuxAtspi.h"
/* Desktop ABI headers shared with Windows: one copy, in CWindowsSupport/include. */
#include "../../CWindowsSupport/include/VoiceSources.h"
#include "../../CWindowsSupport/include/VoiceAudioCodec.h"
#include "../../CWindowsSupport/include/VoiceCredentials.h"
#include "../../CWindowsSupport/include/LocalCleanup.h"

/* Domain headers, in declaration order. */
#include "LinuxComparison.h"
#include "LinuxWindowEvents.h"
#include "LinuxIssueReport.h"
#include "LinuxWindowCommands.h"
#include "LinuxWindowConfiguration.h"
#include "LinuxWindowModels.h"
#include "LinuxWindowRun.h"
#include "LinuxSettingsDialogs.h"
#include "LinuxWindowPresentation.h"
#include "LinuxClipboard.h"
#include "LinuxCredentials.h"
#include "LinuxCloudSync.h"
#include "LinuxAudioCapture.h"
#include "LinuxAudioPlayback.h"
#include "LinuxPrivateFiles.h"
#include "LinuxLocalModels.h"
#include "LinuxX11.h"
#include "LinuxPortals.h"
#include "LinuxDiagnostics.h"

/*
 * The narrow C ABI between the Swift Linux host and GTK 4/libadwaita, libpulse,
 * libsecret, X11/XTest and the XDG desktop portals. It mirrors the Windows
 * adapter: every fallible call returns 0 on success and writes a user-facing
 * UTF-8 message into `error` otherwise. Strings passed in are copied before the
 * call returns. Callbacks never run after the matching stop/destroy returns.
 */

#endif
