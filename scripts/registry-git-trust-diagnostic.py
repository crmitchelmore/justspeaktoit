"""Isolated Git ownership observations. Never modifies checkout/global config."""

import argparse
import hashlib
import json
import os
import pathlib
import pwd
import shutil
import signal
import subprocess
import tempfile
import time


def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    destination = pathlib.Path(args.output)
    if destination.exists():
        raise RuntimeError("Diagnostic output already exists.")
    checkout = pathlib.Path.cwd()
    metadata = checkout / ".git"
    if not metadata.is_dir() or metadata.is_symlink():
        raise RuntimeError("Expected an actual checkout Git directory, not an alias/worktree.")
    controls = {str(metadata / name): digest(metadata / name) for name in ("config", "index")}
    git = shutil.which("git")
    if not git or os.geteuid() != 0:
        raise RuntimeError("Existing GNU Git and container root are required for fixture-only ownership setup.")
    nobody = pwd.getpwnam("nobody")
    if nobody.pw_uid == 0:
        raise RuntimeError("Fixture owner must be non-root.")
    records = []
    payload = dict(
        diagnosticOnly=True, checkoutPWD=os.environ.get("PWD"), checkoutPhysical=str(checkout.resolve()),
        invokingUID=os.geteuid(), fixtureOwnerUID=nobody.pw_uid, gitPath=git,
        gitResolved=str(pathlib.Path(git).resolve()), gitSHA256=digest(git),
        relevantEnvironment={name: os.environ.get(name) for name in (
            "HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM", "SUDO_UID")},
        configInjectionVariableNames=sorted(name for name in os.environ if name.startswith(
            ("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")) or name in (
                "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_DIR", "GIT_WORK_TREE")),
        checkoutControlsBefore=controls, commands=records)
    environment = os.environ.copy()
    for name in list(environment):
        if name.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")) or name in (
            "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG", "GIT_DIR", "GIT_WORK_TREE",
            "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
            del environment[name]
    isolated = environment | {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}

    def run(label, argv, cwd, env):
        start = time.time()
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            records.append(dict(label=label, argv=argv, cwd=str(cwd), started=start, timedOut=True,
                                exit=process.returncode, stdout=stdout.decode(errors="replace"),
                                stderr=stderr.decode(errors="replace")))
            raise
        records.append(dict(label=label, argv=argv, cwd=str(cwd), started=start, ended=time.time(),
                            timedOut=False, exit=process.returncode,
                            stdout=stdout.decode(errors="replace"), stderr=stderr.decode(errors="replace")))
        return process.returncode, stdout, stderr

    try:
        for label, argv in (
            ("version", [git, "--version"]),
            ("package", ["dpkg-query", "-W", "git"]),
            ("ambient-safe-origins", [git, "config", "--show-origin", "--show-scope", "--get-all", "safe.directory"]),
            ("command-safe-origins", [git, "-c", "safe.directory=" + os.environ.get("PWD", str(checkout)),
                                      "config", "--show-origin", "--show-scope", "--get-all", "safe.directory"]),
        ):
            code, _, _ = run(label, argv, "/", environment)
            if code not in ((0, 1) if label.endswith("origins") else (0,)):
                raise RuntimeError(f"Read-only metadata command failed: {label}")
        fixture = pathlib.Path(tempfile.mkdtemp(prefix="jsti-registry-git-diagnostic-", dir="/"))
        payload["retainedFixture"] = str(fixture)
        os.chmod(fixture, 0o700)
        for name in ("one.txt", "space file.txt"):
            file = fixture / name
            file.write_bytes(("synthetic " + name + "\n").encode())
            os.chmod(file, 0o600)
            os.chown(file, nobody.pw_uid, nobody.pw_gid)
        os.chown(fixture, nobody.pw_uid, nobody.pw_gid)
        for label, command in (
            ("fixture-init", [git, "init", "--quiet", "--template=", str(fixture)]),
            ("fixture-explicit-add", [git, "-C", str(fixture), "add", "--", "one.txt", "space file.txt"]),
        ):
            code, _, _ = run(label, ["runuser", "-u", "nobody", "--"] + command, fixture, isolated)
            if code:
                raise RuntimeError(f"Fixture-only setup failed: {label}")
        before = {name: digest(fixture / ".git" / name) for name in ("config", "index")}
        observed_owners = {
            "directory": fixture.stat().st_uid,
            "config": (fixture / ".git" / "config").stat().st_uid,
            "index": (fixture / ".git" / "index").stat().st_uid,
        }
        payload["fixtureOwnerObserved"] = observed_owners
        if any(owner != nobody.pw_uid for owner in observed_owners.values()):
            raise RuntimeError("Actual fixture ownership is not the requested foreign identity.")
        expected = b"one.txt\0space file.txt\0"
        for label, command in (
            ("unscoped", [git, "ls-files", "-z"]),
            ("current-command-scope", [git, "-c", "safe.directory=" + str(fixture), "ls-files", "-z"]),
            ("explicit-exact-root", [git, "--git-dir=" + str(fixture / ".git"),
                                     "--work-tree=" + str(fixture), "ls-files", "-z"]),
        ):
            code, stdout, stderr = run(label, command, fixture, isolated)
            if label == "unscoped":
                if code != 128 or b"dubious ownership" not in stderr:
                    raise RuntimeError("Unscoped refusal was not reproduced.")
            elif code == 0:
                if stdout != expected:
                    raise RuntimeError(f"Tracked listing is not byte-exact: {label}")
            elif code != 128 or b"dubious ownership" not in stderr:
                raise RuntimeError(f"Unexpected scoped-read failure: {label}")
        after = {name: digest(fixture / ".git" / name) for name in ("config", "index")}
        if after != before:
            raise RuntimeError("Fixture index/config changed.")
        payload["fixtureControlsBeforeAfter"] = before
        payload["expectedListingHex"] = expected.hex()
        payload["completed"] = True
    except Exception as error:
        payload["completed"] = False
        payload["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        after = {str(metadata / name): digest(metadata / name) for name in ("config", "index")}
        payload["checkoutControlsAfter"] = after
        payload["checkoutUnchanged"] = after == controls
        with destination.open("x") as stream:
            json.dump(payload, stream, indent=2)
            stream.write("\n")
        if after != controls:
            raise RuntimeError("Checkout index/config changed.")
    return 0 if records[-1]["exit"] == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
