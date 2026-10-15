#!/usr/bin/env bash
set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
gate=/recipe/registry-linux-supported-fs-gate.py
anchor=/jsti-qualified
evidence="$anchor/evidence"
work="$anchor/work"

bounded() {
    local label="$1" seconds="$2"
    shift 2
    python3 "$gate" run "$evidence" "$label" "$seconds" -- "$@"
}

if [ "${1:-}" != nonroot ]; then
    test "$#" = 0
    test "$(id -u)" = 0
    test ! -L "$anchor"
    test "$(stat -c '%u:%g:%a' "$anchor")" = 0:0:755
    test -z "$(find "$anchor" -mindepth 1 -maxdepth 1 -print -quit)"
    mkdir -m 700 "$evidence"
    exec > "$evidence/bootstrap.stdout.log" 2> "$evidence/bootstrap.stderr.log"
    bootstrap_exit() {
        code=$?
        trap - EXIT
        printf 'bootstrapExit=%s\n' "$code" > "$evidence/bootstrap-status.log"
        exit "$code"
    }
    trap bootstrap_exit EXIT
    : "${EXPECTED_HEAD:?}" "${EXPECTED_TREE:?}"
    test "$(id -u nobody):$(id -g nobody)" = 65534:65534
    for tool in python3 git clang swift timeout runuser sha256sum; do command -v "$tool"; done
    bounded recipe-binding 30 python3 - <<'PY'
import hashlib, json, os, pathlib
root = pathlib.Path("/recipe")
binding = json.loads((root / "binding.json").read_text())
if binding["head"] != os.environ["EXPECTED_HEAD"] or binding["tree"] != os.environ["EXPECTED_TREE"]:
    raise ValueError("Recipe source identity mismatch")
for name, expected in binding["recipeSHA256"].items():
    path = root / name
    if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError("Recipe file/hash mismatch: " + name)
for name, expected in binding["manifestSHA256"].items():
    if hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
        raise ValueError("Readonly manifest hash mismatch: " + name)
print(json.dumps(binding))
PY
    bounded actual-head 30 git --git-dir=/source/.git --work-tree=/source rev-parse HEAD
    bounded actual-tree 30 git --git-dir=/source/.git --work-tree=/source rev-parse 'HEAD^{tree}'
    test "$(cat "$evidence/actual-head.stdout.log")" = "$EXPECTED_HEAD"
    test "$(cat "$evidence/actual-tree.stdout.log")" = "$EXPECTED_TREE"
    bounded readonly-status 30 git --git-dir=/source/.git --work-tree=/source status --porcelain=v1 -z --untracked-files=all
    test ! -s "$evidence/readonly-status.stdout.log"
    mkdir -m 700 "$work"
    bounded copy-source 120 python3 "$gate" copy /source "$work" /recipe/source-plan.json "$evidence/copy-verification.json"
    bounded private-ownership 60 python3 - "$work" "$evidence" <<'PY'
import os, pathlib, stat, sys
for root in map(pathlib.Path, sys.argv[1:]):
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = pathlib.Path(parent) / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ValueError("Unsafe copied ownership target")
            os.chown(path, 65534, 65534, follow_symlinks=False)
        os.chown(parent, 65534, 65534, follow_symlinks=False)
    root.chmod(0o700)
PY
    nonroot=0
    bounded dropped-process 1500 runuser -u nobody -- env \
        HOME="$work/.home" TMPDIR="$work/.runtime" SPEAK_PORTABLE_CORE=1 \
        EXPECTED_HEAD="$EXPECTED_HEAD" EXPECTED_TREE="$EXPECTED_TREE" \
        bash /recipe/registry-linux-supported-fs-container.sh nonroot || nonroot=$?
    exit "$nonroot"
fi

test "$#" = 1
cd "$work"
native=unreached
capability=unreached
swift=unreached
lock=unreached
finish() {
    code=$?
    trap - EXIT
    set +e
    if [ -f "$evidence/root-lock.before.raw" ]; then
        bounded restore-lock 15 python3 - "$evidence/root-lock.before.raw" "$work/Package.resolved" <<'PY'
import hashlib, os, pathlib, stat, sys
before, target = map(pathlib.Path, sys.argv[1:])
data = before.read_bytes()
if target.exists() or target.is_symlink():
    if not stat.S_ISREG(target.lstat().st_mode) or target.is_symlink():
        raise ValueError("Unsafe lockfile restore target")
fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, "wb") as stream:
    stream.write(data)
if target.read_bytes() != data:
    raise ValueError("Lockfile restore byte mismatch")
after = before.with_name("root-lock.after.raw")
with after.open("xb") as stream:
    stream.write(target.read_bytes())
print("preservedRootLockSHA256=" + hashlib.sha256(data).hexdigest())
PY
        lock=$?
    fi
    bounded final-status 15 python3 "$gate" status "$evidence/qualification-status.json" \
        "$native" "$capability" "$swift" "$lock"
    status=$?
    printf 'droppedProcessExit=%s statusGateExit=%s\n' "$code" "$status" > "$evidence/dropped-status.log"
    if [ "$code" -ne 0 ]; then exit "$code"; fi
    exit "$status"
}
trap finish EXIT
test "$(id -u):$(id -ru):$(id -g)" = 65534:65534:65534
grep -qx 'CapEff:[[:space:]]*0000000000000000' "/proc/$$/status"
mkdir -m 700 "$HOME" "$TMPDIR"
bounded identity 15 bash -c 'id; grep "^CapEff:" /proc/$$/status; stat -c "%n owner=%u group=%g mode=%a device=%d inode=%i" / /jsti-qualified "$PWD" "$HOME" "$TMPDIR"; cat /proc/self/cgroup'
for directory in "$PWD" "$HOME" "$TMPDIR"; do
    test ! -L "$directory"
    test "$(stat -c '%u:%g:%a' "$directory")" = 65534:65534:700
done
bounded resources 15 python3 "$gate" resources "$work"
bounded tool-swift 15 swift --version
bounded tool-git 15 git --version
bounded tool-python 15 python3 --version
bounded tool-hashes 30 python3 - <<'PY'
import hashlib, json, pathlib, shutil
for name in ("swift", "git", "clang", "python3", "runuser", "timeout"):
    path = pathlib.Path(shutil.which(name)).resolve(strict=True)
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(part)
    print(json.dumps({"tool": name, "resolved": str(path), "sha256": digest.hexdigest()}))
PY
bounded source-inputs 30 sha256sum Package.resolved scripts/registry-linux-capability-diagnostic.c \
    Sources/CRecordingFileSupport/RecordingFileSupport.c Sources/CRecordingFileSupport/include/CRecordingFileSupport.h
bounded lock-before 15 python3 - "$evidence/root-lock.before.raw" <<'PY'
import hashlib, json, pathlib, sys
data = pathlib.Path("Package.resolved").read_bytes()
binding = json.loads(pathlib.Path("/recipe/binding.json").read_text())
if hashlib.sha256(data).hexdigest() != binding["rootLockSHA256"]:
    raise ValueError("Copied lockfile differs from frozen source")
with open(sys.argv[1], "xb") as stream:
    stream.write(data)
print("rootLockSHA256=" + hashlib.sha256(data).hexdigest())
PY
compiler="$(command -v clang)"
bounded compiler-version 15 "$compiler" --version
bounded compiler-hash 15 sha256sum "$(readlink -f "$compiler")"
bounded compile-cli 60 "$compiler" -std=c11 -Wall -Wextra -Werror -pedantic \
    -MD -MF "$evidence/cli.d" -c scripts/registry-linux-capability-diagnostic.c -o "$evidence/cli.o"
bounded compile-production 60 "$compiler" -std=c11 -Wall -Wextra -Werror -pedantic \
    -MD -MF "$evidence/production.d" -I Sources/CRecordingFileSupport/include \
    -c Sources/CRecordingFileSupport/RecordingFileSupport.c -o "$evidence/production.o"
bounded link 30 "$compiler" "$evidence/cli.o" "$evidence/production.o" \
    -Wl,-Map,"$evidence/link.map" -o "$evidence/registry-linux-capability-diagnostic"
bounded output-hashes 15 sha256sum "$evidence/cli.o" "$evidence/production.o" "$evidence/registry-linux-capability-diagnostic"
native=0
bounded native 15 "$evidence/registry-linux-capability-diagnostic" "$work" "$TMPDIR" 65534 || native=$?
capability=0
bounded capability-gate 15 python3 "$gate" native "$evidence/native.stdout.log" \
    "$evidence/native.stderr.log" "$native" "$evidence/capability-gate.json" || capability=$?
if [ "$native" -ne 0 ] || [ "$capability" -ne 0 ]; then
    printf 'ENVIRONMENT_NOT_ADMITTED: native create/publication gate failed; Swift UNREACHED, not skipped/passing.\n' >&2
    exit 78
fi
swift=0
bounded swift 1200 swift test --configuration release --jobs 4 || swift=$?
bounded final-capacity-bytes 15 df -B1 "$work"
bounded final-capacity-inodes 15 df -i "$work"
exit "$swift"
