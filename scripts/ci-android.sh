#!/usr/bin/env bash
# The Android CI job's build and tests. android.yml, .github/workflows/precheck.yml and
# scripts/pre-pr all run this, so a pre-pr pass means the Android job passes.
# Needs a JDK 17 and, off GitHub-hosted runners, an approved feed in JSTI_MAVEN_MIRROR
# (android/settings.gradle.kts); scripts/pre-pr otherwise runs it remotely.
set -euo pipefail
cd "$(dirname "$0")/../android"
./gradlew --stacktrace testDebugUnitTest lintDebug assembleDebug
