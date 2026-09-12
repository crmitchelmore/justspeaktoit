#!/bin/bash
#
# Sparkle self-update smoke test.
#
#   scripts/sparkle-update-smoke.sh <dmg-path> <appcast-xml-path>
#
# Set SPARKLE_SMOKE_LOCAL_ENCLOSURE=1 before publication to serve the exact
# signed DMG on loopback instead of fetching its not-yet-published GitHub URL.
# Set SPARKLE_SMOKE_REQUIRE_SUPPORTED=1 for release gates (missing smoke support
# then fails instead of skipping compatibility tests for old releases).
#
# Nothing in CI used to install a Sparkle update. Releases were verified by
# inspecting the artefacts, so a broken feed, a bad signature or an installer
# that cannot replace the bundle would first be discovered by a user. On
# 2026-09-02 a user-facing "update error" turned out to be a full disk, and the
# investigation found there was no test that would have caught a genuinely
# broken update either.
#
# WHAT THIS DOES
#
#   1. Mounts the released DMG, reads the shipped app's CFBundleVersion, and
#      copies the app to a temp directory (a throw-away copy is what updates
#      itself; nothing installed on the machine is touched).
#   2. Writes a *synthetic* appcast next to a local HTTP server: the real feed
#      with `sparkle:version` bumped to CFBundleVersion + 1 and everything else
#      — enclosure url, length and sparkle:edSignature — left exactly as
#      published, so the update Sparkle downloads is the real signed DMG.
#   3. Launches the temp copy in headless smoke mode
#      (`--sparkle-smoke-update`, added by Sources/SpeakApp/Services/
#      SparkleSmokeMode.swift and friends) pointed at that feed, and waits for
#      Sparkle to download, verify, install and relaunch it.
#
# WHY THE ASSERTIONS ARE NOT "THE VERSION WENT UP"
#
# The synthetic appcast advertises CFBundleVersion + 1 but re-uses the real
# enclosure, and the DMG behind it contains the *same* CFBundleVersion as the
# copy that is running. That is deliberate: re-signing a doctored DMG would need
# the release private key, and using an unsigned one would test nothing. So
# after a successful install the bundle reports the enclosure's version, not the
# bumped one. The round trip is therefore asserted as:
#
#   * Sparkle reported `installing` (it accepted the item, verified the EdDSA
#     signature, downloaded, extracted and reached the install-and-relaunch
#     step);
#   * both the bundle and executable filesystem identities changed, proving an
#     actual replacement rather than an install request followed by failure;
#   * the replaced bundle at the temp path has a valid code signature;
#   * its CFBundleVersion equals the version inside the enclosure DMG (read from
#     the mount up front) — i.e. the bundle really was swapped for the
#     downloaded one and is not a half-written directory;
# Relaunch observation remains advisory on headless CI (issue #878). The
# required replacement witness, signature, and version checks prove installation;
# they do not prove GUI relaunch survival in an interactive user session.
#
# Exit status: 0 on PASS or SKIPPED, non-zero on FAIL.
#
# SKIPPED: an app that predates the smoke flag has no
# `SpeakSparkleSmokeSupported` marker in its Info.plist. The job then prints a
# SKIPPED line and exits 0, so the release workflow can adopt this before the
# first release that contains the flag.

set -uo pipefail

DMG_PATH="${1:-}"
APPCAST_PATH="${2:-}"

if [ -z "$DMG_PATH" ] || [ -z "$APPCAST_PATH" ]; then
    echo "Usage: $0 <dmg-path> <appcast-xml-path>" >&2
    exit 64
fi
if [ ! -f "$DMG_PATH" ]; then
    echo "FAIL: no such DMG: $DMG_PATH" >&2
    exit 1
fi
if [ ! -f "$APPCAST_PATH" ]; then
    echo "FAIL: no such appcast: $APPCAST_PATH" >&2
    exit 1
fi

# Six minutes for the whole update: the enclosure is downloaded from GitHub,
# mounted, copied and installed.
UPDATE_TIMEOUT_SECONDS="${SPARKLE_SMOKE_TIMEOUT:-360}"
# The relaunched process appears a moment after the original exits.
RELAUNCH_TIMEOUT_SECONDS=60

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-smoke.XXXXXX")"
MOUNT_POINT="$WORK_DIR/mnt"
APP_DIR="$WORK_DIR/app"
FEED_DIR="$WORK_DIR/feed"
RESULT_FILE="$WORK_DIR/result.json"
SERVER_PID=""
APP_PID=""
APP_COPY=""
FAILED=0

log() { printf '==> %s\n' "$*"; }

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    # The relaunched app (and any lingering original) belongs to the temp copy
    # only; never touch an installed JustSpeakToIt.
    if [ -n "$APP_COPY" ]; then
        pkill -f "^${APP_COPY}/Contents/MacOS/" 2>/dev/null || true
    fi
    if [ -d "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" -quiet -force 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    FAILED=1
}

dump_diagnostics() {
    echo "--- result file ($RESULT_FILE) ---" >&2
    if [ -f "$RESULT_FILE" ]; then
        cat "$RESULT_FILE" >&2
        echo >&2
    else
        echo "(the smoke run wrote no result file)" >&2
    fi
    echo "--- unified log ---" >&2
    log show --last 10m \
        --predicate 'subsystem == "org.sparkle-project.Sparkle" OR process == "JustSpeakToIt"' \
        2>/dev/null | tail -300 >&2 || echo "(log show produced nothing)" >&2
}

# --- 1. The published DMG -----------------------------------------------------

mkdir -p "$MOUNT_POINT" "$APP_DIR" "$FEED_DIR"

log "Mounting $DMG_PATH"
if ! hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -readonly -quiet; then
    echo "FAIL: could not mount $DMG_PATH" >&2
    exit 1
fi

MOUNTED_APP="$(find "$MOUNT_POINT" -maxdepth 1 -name '*.app' -print -quit)"
if [ -z "$MOUNTED_APP" ]; then
    echo "FAIL: no .app found on the mounted DMG" >&2
    exit 1
fi

# The version inside the enclosure: what the bundle must report *after* a
# successful install, because the update re-uses this very DMG.
ENCLOSURE_APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$MOUNTED_APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [ -z "$ENCLOSURE_APP_VERSION" ]; then
    echo "FAIL: could not read CFBundleVersion from $MOUNTED_APP" >&2
    exit 1
fi
log "Enclosure app version (CFBundleVersion): $ENCLOSURE_APP_VERSION"

APP_NAME="$(basename "$MOUNTED_APP")"
APP_COPY="$APP_DIR/$APP_NAME"
log "Copying $APP_NAME to $APP_COPY"
if ! ditto "$MOUNTED_APP" "$APP_COPY"; then
    echo "FAIL: could not copy the app off the DMG" >&2
    exit 1
fi
hdiutil detach "$MOUNT_POINT" -quiet -force 2>/dev/null || true

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$APP_COPY/Contents/Info.plist" 2>/dev/null || echo "JustSpeakToIt")"
APP_EXECUTABLE="$APP_COPY/Contents/MacOS/$EXECUTABLE_NAME"

# --- 2. Does this build understand the smoke flags? ---------------------------

SMOKE_SUPPORTED="$(defaults read "$APP_COPY/Contents/Info.plist" SpeakSparkleSmokeSupported 2>/dev/null || echo "")"
if [ "$SMOKE_SUPPORTED" != "1" ]; then
    if [ "${SPARKLE_SMOKE_REQUIRE_SUPPORTED:-0}" = "1" ]; then
        echo "FAIL: release gate requires SpeakSparkleSmokeSupported in Info.plist" >&2
        exit 1
    fi
    echo "SKIPPED: $APP_NAME (build $ENCLOSURE_APP_VERSION) predates the headless Sparkle smoke mode"
    echo "         (no SpeakSparkleSmokeSupported marker in Info.plist); nothing to exercise."
    exit 0
fi

# --- 3. The synthetic appcast -------------------------------------------------

RUNNING_VERSION="$ENCLOSURE_APP_VERSION"
case "$RUNNING_VERSION" in
    ''|*[!0-9]*)
        echo "FAIL: CFBundleVersion '$RUNNING_VERSION' is not numeric; cannot bump it" >&2
        exit 1
        ;;
esac
BUMPED_VERSION="$((10#$RUNNING_VERSION + 1))"
log "Synthetic appcast will advertise sparkle:version $BUMPED_VERSION (running $RUNNING_VERSION)"

PORT="$(python3 -c 'import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()')"
FEED_URL="http://127.0.0.1:$PORT/appcast.xml"
LOCAL_ENCLOSURE_URL=""
if [ "${SPARKLE_SMOKE_LOCAL_ENCLOSURE:-0}" = "1" ]; then
    # A symlink keeps the exact signed DMG bytes intact without another large
    # copy. This server is loopback-only and disappears with the smoke run.
    ABSOLUTE_DMG="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
    if ! ln -s "$ABSOLUTE_DMG" "$FEED_DIR/enclosure.dmg"; then
        echo "FAIL: could not expose the local signed enclosure" >&2
        exit 1
    fi
    LOCAL_ENCLOSURE_URL="http://127.0.0.1:$PORT/enclosure.dmg"
fi

if ! python3 "$(dirname "$0")/prepare-sparkle-smoke-feed.py" \
    "$APPCAST_PATH" "$FEED_DIR/appcast.xml" "$BUMPED_VERSION" "$LOCAL_ENCLOSURE_URL"; then
    echo "FAIL: could not build the synthetic appcast from $APPCAST_PATH" >&2
    exit 1
fi

# --- 4. Serve it on loopback --------------------------------------------------

log "Serving $FEED_DIR at $FEED_URL"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED_DIR" \
    >"$WORK_DIR/http.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
    if curl -sf -o /dev/null "$FEED_URL"; then break; fi
    sleep 0.2
done
if ! curl -sf -o /dev/null "$FEED_URL"; then
    echo "FAIL: the local appcast server never answered on $FEED_URL" >&2
    cat "$WORK_DIR/http.log" >&2 || true
    exit 1
fi

# --- 5. Let the app update itself ---------------------------------------------
#
# The app reaches the http feed because Config/AppInfo.plist declares
# NSAllowsLocalNetworking: without it App Transport Security blocks plain HTTP
# to 127.0.0.1 even from a notarised build. The exemption covers loopback,
# .local and link-local addresses only.

REPLACEMENT_HELPER="$(dirname "$0")/verify-sparkle-replacement.py"
if ! ORIGINAL_IDENTITY="$(python3 "$REPLACEMENT_HELPER" snapshot "$APP_COPY" "$APP_EXECUTABLE")"; then
    echo "FAIL: could not record the original bundle identity" >&2
    exit 1
fi

log "Launching $APP_EXECUTABLE in smoke mode"
"$APP_EXECUTABLE" \
    --sparkle-smoke-update \
    --sparkle-feed-url "$FEED_URL" \
    --sparkle-result-file "$RESULT_FILE" \
    >"$WORK_DIR/app.log" 2>&1 &
APP_PID=$!
log "Smoke process PID $APP_PID; waiting up to ${UPDATE_TIMEOUT_SECONDS}s"

WAITED=0
while kill -0 "$APP_PID" 2>/dev/null; do
    if [ "$WAITED" -ge "$UPDATE_TIMEOUT_SECONDS" ]; then
        fail "the smoke process did not finish within ${UPDATE_TIMEOUT_SECONDS}s"
        kill -9 "$APP_PID" 2>/dev/null || true
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done
wait "$APP_PID" 2>/dev/null
APP_EXIT=$?
log "Smoke process exited with status $APP_EXIT after ${WAITED}s"

# --- 6. Assertions ------------------------------------------------------------

# 6a. Sparkle reported that it was installing.
RESULT_STATE=""
if [ -f "$RESULT_FILE" ]; then
    RESULT_STATE="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("result", ""))
except Exception:
    print("")' "$RESULT_FILE")"
fi
if [ "$RESULT_STATE" = "installing" ]; then
    log "OK: Sparkle reported \"installing\""
else
    fail "expected the result file to report \"installing\", got \"${RESULT_STATE:-<nothing>}\""
fi

# 6b. An install request is not proof of replacement. Wait for Sparkle's helper
# to replace both filesystem objects after the parent exits, then verify bytes.
if ! python3 "$REPLACEMENT_HELPER" wait "$APP_COPY" "$APP_EXECUTABLE" \
    "$ORIGINAL_IDENTITY" "$RELAUNCH_TIMEOUT_SECONDS"; then
    fail "no completed bundle/executable replacement was observed"
fi

# 6c. The replaced bundle is intact and still validly signed.
if codesign --verify --strict "$APP_COPY" 2>"$WORK_DIR/codesign.log"; then
    log "OK: the installed bundle passes codesign --verify --strict"
else
    fail "the installed bundle failed code signature validation: $(cat "$WORK_DIR/codesign.log")"
fi

# 6d. The bundle now reports the version that was inside the enclosure DMG.
#     (Not the bumped one — see the header: the synthetic appcast re-uses the
#     real enclosure, whose app carries the original CFBundleVersion.)
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP_COPY/Contents/Info.plist" 2>/dev/null || echo "")"
if [ "$INSTALLED_VERSION" = "$ENCLOSURE_APP_VERSION" ]; then
    log "OK: the bundle reports the enclosure's CFBundleVersion ($INSTALLED_VERSION)"
else
    fail "expected CFBundleVersion $ENCLOSURE_APP_VERSION after install, got \"${INSTALLED_VERSION:-<nothing>}\""
fi

# 6e. Sparkle relaunched the app from the same bundle path.
RELAUNCHED_PID=""
WAITED=0
while [ "$WAITED" -lt "$RELAUNCH_TIMEOUT_SECONDS" ]; do
    RELAUNCHED_PID="$(pgrep -f "^${APP_EXECUTABLE}" | head -1)"
    if [ -n "$RELAUNCHED_PID" ]; then break; fi
    sleep 2
    WAITED=$((WAITED + 2))
done
if [ -n "$RELAUNCHED_PID" ]; then
    log "OK: the updated app is running again (PID $RELAUNCHED_PID)"
    kill "$RELAUNCHED_PID" 2>/dev/null || true
else
    # Advisory only. The required assertions above prove replacement of both
    # filesystem objects followed by a valid signature and enclosure version. Whether the *relaunched* GUI process
    # survives depends on the session it is launched into: on a headless
    # GitHub runner the relaunch is not reliably observable (issue #878),
    # while on a real Mac it appears within a couple of seconds.
    log "WARN: the updated app was not observed running again within ${RELAUNCH_TIMEOUT_SECONDS}s (relaunch is advisory on CI)"
fi

# --- 7. Verdict ---------------------------------------------------------------

if [ "$FAILED" -ne 0 ]; then
    dump_diagnostics
    echo "FAIL: Sparkle update smoke test failed for $APP_NAME (build $ENCLOSURE_APP_VERSION)"
    exit 1
fi

echo "PASS: Sparkle update smoke test installed $APP_NAME (build $ENCLOSURE_APP_VERSION)"
exit 0
