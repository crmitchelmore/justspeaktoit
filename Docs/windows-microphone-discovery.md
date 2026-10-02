# Windows microphone discovery

The microphone picker follows device connections, removals, state/name changes
and the default communications device while the app is running. An explicit
selection always retains its exact endpoint ID. Unplugging it produces an
unavailable row when the picker next becomes idle; it never selects a different
device or changes saved preferences. The empty ID continues to mean the current
Windows communications default. The label identifies that default when available.

`WindowsAudioDeviceMonitor.cpp` owns one worker and an `IMMNotificationClient`.
Windows event callbacks perform atomic state changes and signal an event only.
They do not enumerate, call Swift, wait for locks, unregister or release native
objects. Repeated changes coalesce, including changes received while enumeration
is running. The worker obtains a complete list through the existing enumeration
boundary, sorts it consistently, and suppresses unchanged snapshots. There is
no polling timer or task/thread for every notification.

`WindowsMicrophoneMonitor` owns the native handle. Its stateless callback forwards
borrowed rows synchronously into the native window's latest-snapshot mailbox,
which copies all strings before return. No Swift context pointer is passed to
the worker. Startup enumeration also runs outside the UI/controller actor.

`jsti_window_refresh_microphones` validates a whole snapshot before accepting it.
Duplicate/empty endpoint IDs, invalid UTF-8 and multiple default markers reject
the snapshot without changing the displayed list. Enumeration failures keep the
last complete list and display a refresh-unavailable label. Success clears that
label. Rebuilds emit no user-selection event. The picker reads its current exact
selection at application time, so a user choice made during enumeration wins.
Recording/busy states retain the latest pending snapshot, keep the picker locked,
and apply it on return to idle. They do not change the active capture's endpoint.

Closing the window signals cancellation immediately. After the native window
loop returns, shutdown unregisters and joins the monitor on a background task;
the controller actor and UI thread do not wait for device enumeration. The
callback object remains owned through unregister, enumerator release and active
callback drain. Destroy rejects a call from its own snapshot callback, preventing
self-join. An unexpected native unregister failure retains an inert registration
rather than freeing an object still reachable by Windows; this does not retain a
Swift callback context. The host creates one monitor per window lifetime.

These lifetime rules follow Microsoft's [IMMNotificationClient contract](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient)
and [registration ownership rules](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nf-mmdeviceapi-immdeviceenumerator-registerendpointnotificationcallback).

The native synthetic monitor test uses an injected backend without touching
hardware. It verifies 10,000 events during a blocked enumeration produce one
follow-up snapshot, changed capture defaults refresh, unrelated default roles
are ignored, callback self-destruction is rejected, and cancellation suppresses
an in-flight snapshot before unregister/join. Window smoke tests check runtime
refresh, exact selected IDs, unavailable/restored rows, changing defaults,
recording lockout, invalid snapshots, latest-only updates, empty lists and
preserved transcript/status. Windows runtime execution of these new tests is a
separate gate from compilation. Physical USB/Bluetooth connection, permission,
sleep/resume and disconnect-during-recording journeys remain acceptance gates.
