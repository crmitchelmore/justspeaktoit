# Focus capture overrides

The opt-in Capture Overrides filter selects existing destination, model and
language choices for headless Action Button, Siri, Shortcuts and related service
entry points. The independent in-app microphone controller keeps its own settings;
keyboard profiles retain complete ownership and ignore Focus. This increment does
not add profiles, spoken routing, Send to Mac, a new extension or Focus-status
permission. Configure the filter in Settings > Focus > Add Filter.

Each admitted capture freezes explicit Start inputs, reconciled Focus choices and
global model, mode, language and destination before credential loading. Explicit
fields win over Focus, which wins over global preferences. A foreground-continuation
retry reuses that same snapshot. An explicit Stop destination can intentionally
redirect the run; typed hardware, automatic and interruption stops retain its
frozen selection and origin. The exported legacy Stop with no destination retains
clipboard and automatic-polish behavior when there is no destination override;
Focus, explicit Start and keyboard destination contexts remain authoritative.
Named Focus models follow the same strict capability,
credential and offline rules as named Start models, with no silent provider fallback.

The App Group contains a versioned local envelope and a generation marker; neither
contains transcripts, Focus names or credentials, and neither is exported with
settings. Native default perform removes the envelope while advancing generation.
A stable, nonblocking interprocess lock protects reads and writes. Reconciliation
reads the native current filter only after this store has been configured and
commits only if its generation remains unchanged. A newer perform or reset wins.
A missing envelope in a verified never-configured store means no override;
unavailable, corrupt or incomplete storage cannot establish that and refuses start.
Native lookup failure preserves the latest stored choice and refuses an affected
start, including History-only, rather than changing it to clipboard delivery.

Invalid supplied choices replace previous valid choices and are checked again at
admission. An explicit valid field can supersede an invalid Focus field without
discarding other valid Focus fields. History-only captures save History according
to existing policy, including configured sync, but publish no immediate keyboard
offer, clipboard, shared result preview, Handoff pointer or polish request.

Phone capture status shows the frozen destination and a Focus label when Focus
supplied it. Settings shows the last received local selection and a reset action.
Local reset does not disable a system filter: an active filter can apply again at
the next native reconciliation. Change or remove it in system Settings for a
lasting change. No Focus name is inferred or logged.

Source implementation and automated regressions are separate from native and
device qualification. App Intents metadata extraction and app/widget builds must
verify existing target membership before any extension or signing change. Physical
Settings discovery, activation/change/deactivation/default reset, cold/background
perform, locked/protected storage and visible next-run behavior remain acceptance
gates. The independent in-app recorder remains a separate integration decision.
No release or issue closure follows from source or simulator tests alone.
