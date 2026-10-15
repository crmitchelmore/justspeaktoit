"""Opt-in hosted-CI resource ownership, source-copy and native capability gates."""
import hashlib
import json
import os
import pathlib
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
from datetime import datetime, timezone

IMAGE = "swift:6.2.3-jammy@sha256:33c73fc133767cdaafde26f0f9967c96ab25ff77618b7df1eabf46140bf2b6e6"
MEMORY = 4 * 1024**3
RECIPES = ("registry-linux-supported-fs-host.sh", "registry-linux-supported-fs-container.sh",
           "registry-linux-supported-fs-gate.py")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def save(path, value):
    with pathlib.Path(path).open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=True)
        stream.write("\n")


def load(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def sha(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(part)
    return digest.hexdigest()


def run(folder, label, seconds, argv):
    folder = pathlib.Path(folder)
    require(re.fullmatch(r"[a-z0-9-]+", label), "Invalid command label")
    command = ["timeout", "--kill-after=2s", str(seconds) + "s", *argv]
    record = {"argv": command, "commandArgv": argv, "budgetSeconds": seconds,
              "startedUTC": datetime.now(timezone.utc).isoformat(), "wrapperPID": None,
              "outerDeadlineExceeded": False, "processJoinUnconfirmed": False}
    with (folder / (label + ".stdout.log")).open("xb") as stdout, \
            (folder / (label + ".stderr.log")).open("xb") as stderr:
        try:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True,
                                       env={**os.environ, "GIT_OPTIONAL_LOCKS": "0", "PYTHONDONTWRITEBYTECODE": "1"})
            record["processJoinUnconfirmed"] = True
            record["wrapperPID"] = process.pid
            try:
                result = process.wait(timeout=seconds + 5)
                record["processJoinUnconfirmed"] = False
            except subprocess.TimeoutExpired:
                record["outerDeadlineExceeded"] = True
                record["processJoinUnconfirmed"] = True
                os.killpg(process.pid, signal.SIGKILL)
                try:
                    result = process.wait(timeout=5)
                    record["processJoinUnconfirmed"] = False
                except subprocess.TimeoutExpired:
                    result = 124
            record["exit"] = result
        except OSError as error:
            stderr.write((str(error) + "\n").encode())
            record["exit"] = 127
    record["endedUTC"] = datetime.now(timezone.utc).isoformat()
    record["timeoutOrKilled"] = killed_or_timed_out(record["exit"]) or record["outerDeadlineExceeded"]
    record["stdoutSHA256"] = sha(folder / (label + ".stdout.log"))
    record["stderrSHA256"] = sha(folder / (label + ".stderr.log"))
    save(folder / (label + ".command.json"), record)
    return record["exit"]


def one(text, pattern):
    values = re.findall(pattern, text, re.MULTILINE)
    require(len(values) == 1, "Expected exactly one observation: " + pattern)
    return values[0]


def native_gate(stdout, stderr, native_exit):
    require(native_exit == 0 and not stderr and "observation=unavailable" not in stdout
            and "diagnostic-error" not in stdout, "Native CLI nonzero, unavailable or error")
    pid = int(one(stdout, r"^pid=(\d+) uid=65534 euid=65534 gid=65534 HOME=/jsti-qualified/work/\.home "
                         r"TMPDIR=/jsti-qualified/work/\.runtime$"))
    require(pid > 0, "Invalid native self-reported PID")
    one(stdout, r"^CapEff:\s+0000000000000000$")
    fd = int(one(stdout, r"^native-create primary_errno=0 unsupported=0 owned_fd=(\d+) cleanup_errno=0$"))
    anonymous_device = one(stdout, r"^anonymous dev=(\d+) inode=\d+ owner=65534 mode=600 nlink=0 size=0$")
    one(stdout, r"^native-publish primary_errno=0 unsupported=0 did_publish=1 cleanup_errno=0$")
    one(stdout, r"^observation=available published=1 mode=400 nlink=1 diagnosticBytesOnly=1$")
    one(stdout, r"^diagnostic-exit=0 retainedFixture=1$")
    filesystems = {}
    for role, path in (("source", "/jsti-qualified/work"), ("parent", "/jsti-qualified/work/.runtime")):
        values = one(stdout, r"^" + role + " path=" + re.escape(path)
                     + r" dev=(\d+) major=(\d+) minor=(\d+) inode=\d+ owner=65534 mode=700 "
                     r"fstatfsType=(0x[0-9a-f]+) statfsType=(0x[0-9a-f]+) fsid=([0-9a-f]+:[0-9a-f]+)$")
        device, major, minor, held, named, fsid = values
        require(held == named, "Held/named filesystem mismatch")
        filesystems[role] = {"device": device, "major": major, "minor": minor, "type": held, "fsid": fsid}
    require(filesystems["source"] == filesystems["parent"], "Source/parent filesystem identity differs")
    fs = filesystems["source"]
    require(anonymous_device == fs["device"], "Anonymous allocation on a different device")
    require(re.search(r"^selected-mountinfo \d+ \d+ " + fs["major"] + ":" + fs["minor"] + r" ",
                      stdout, re.MULTILINE), "Missing actual device mountinfo")
    one(stdout, r"^fixture=/jsti-qualified/work/\.runtime/jsti-registry-capability-[0-9a-f]{32} retained=1$")
    return {"capability": "admitted-for-unchanged-tests", "nativeExit": native_exit,
            "nativeSelfReportedPID": pid, "observedOwnedFD": fd, "filesystems": filesystems,
            "productionQualification": False}


def relative_parts(name):
    require(name and not name.startswith(b"/") and b"\0" not in name, "Invalid tracked path")
    parts = name.split(b"/")
    require(all(part not in (b"", b".", b"..") for part in parts), "Unsafe tracked component")
    return parts


def open_source(root, name):
    parts = relative_parts(name)
    parent = os.dup(root)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        named = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        require(stat.S_ISREG(named.st_mode), "Tracked source must be regular and nonlink")
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        held = os.fstat(fd)
        if not stat.S_ISREG(held.st_mode) or (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
            os.close(fd)
            raise ValueError("Source identity/type changed while opening")
        return fd
    finally:
        os.close(parent)


def read_owned(fd):
    with os.fdopen(fd, "rb") as stream:
        return stream.read()


def source_plan(source, listing, tree):
    paths = pathlib.Path(listing).read_bytes()
    require(paths.endswith(b"\0") and paths != b"\0", "Empty or unterminated NUL manifest")
    names = paths[:-1].split(b"\0")
    require(len(names) == len(set(names)), "Duplicate tracked source")
    entries = {}
    tree_bytes = pathlib.Path(tree).read_bytes()
    require(tree_bytes.endswith(b"\0"), "Unterminated Git tree")
    for item in tree_bytes[:-1].split(b"\0"):
        header, name = item.split(b"\t", 1)
        mode, kind, blob = header.decode("ascii").split()
        require(mode in ("100644", "100755") and kind == "blob", "Nonregular tracked Git entry")
        require(name not in entries and re.fullmatch(r"[0-9a-f]{40}", blob), "Invalid/duplicate tree entry")
        entries[name] = (mode, blob)
    require(set(names) == set(entries), "Index/HEAD manifest mismatch")
    root = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    rows = []
    try:
        for name in names:
            data = read_owned(open_source(root, name))
            mode, blob = entries[name]
            require(hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() == blob,
                    "Source bytes differ from committed blob")
            rows.append({"pathHex": name.hex(), "mode": mode, "blob": blob,
                         "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    finally:
        os.close(root)
    return {"NULManifestSHA256": hashlib.sha256(paths).hexdigest(), "files": rows}


def copy_source(source, destination, plan):
    destination = pathlib.Path(destination)
    require(destination.is_dir() and not destination.is_symlink() and not any(destination.iterdir()),
            "Copy destination must be fresh, empty and nonlink")
    source_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for row in plan["files"]:
            name = bytes.fromhex(row["pathHex"])
            relative_parts(name)
            data = read_owned(open_source(source_fd, name))
            require(len(data) == row["bytes"] and hashlib.sha256(data).hexdigest() == row["sha256"],
                    "Readonly source changed before copy")
            target = destination / os.fsdecode(name)
            target.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            with target.open("xb") as stream:
                stream.write(data)
            target.chmod(0o700 if row["mode"] == "100755" else 0o600)
    finally:
        os.close(source_fd)
    return verify_source(source, destination, plan)


def verify_source(source, destination, plan):
    source_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    copied_fd = None
    try:
        copied_fd = os.open(destination, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        for row in plan["files"]:
            name = bytes.fromhex(row["pathHex"])
            original = read_owned(open_source(source_fd, name))
            copied = read_owned(open_source(copied_fd, name))
            require(original == copied and len(copied) == row["bytes"] and
                    hashlib.sha256(copied).hexdigest() == row["sha256"], "Source/copy byte equivalence failed")
    finally:
        os.close(source_fd)
        if copied_fd is not None:
            os.close(copied_fd)
    require(plan["files"], "Empty source plan")
    return {"verifiedRegularFiles": len(plan["files"]), "NULManifestSHA256": plan["NULManifestSHA256"]}


def resources(root):
    v = os.statvfs(root)
    capacity = {"availableBytes": v.f_bavail * v.f_frsize, "availableInodes": v.f_favail,
                "requiredBytes": 12 * 1024**3, "requiredInodes": 100000,
                "diskQuota": "waived-only-on-exclusive-disposable-GitHub-hosted-VM"}
    print(json.dumps(capacity), flush=True)
    require(capacity["availableBytes"] >= capacity["requiredBytes"] and v.f_favail >= 100000,
            "Insufficient free bytes/inodes; no fallback")
    cgroup = pathlib.Path("/sys/fs/cgroup")
    if (cgroup / "memory.max").is_file():
        memory = int((cgroup / "memory.max").read_text())
        swap = int((cgroup / "memory.swap.max").read_text())
        version = 2
    else:
        memory = int((cgroup / "memory/memory.limit_in_bytes").read_text())
        total = int((cgroup / "memory/memory.memsw.limit_in_bytes").read_text())
        swap = total - memory
        version = 1
    print(json.dumps({"cgroupVersion": version, "memoryBytes": memory, "swapBytes": swap}), flush=True)
    require(memory == MEMORY and swap == 0, "Actual cgroup 4-GiB/no-swap enforcement not observed")


def export_manifest(root):
    rows = []
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = pathlib.Path(parent) / name
            mode = path.lstat().st_mode
            require(not stat.S_ISLNK(mode) and (stat.S_ISDIR(mode) or stat.S_ISREG(mode)),
                    "Export contains link or nonregular entry")
        for name in files:
            path = pathlib.Path(parent) / name
            rows.append({"path": str(path.relative_to(root)), "bytes": path.stat().st_size, "sha256": sha(path)})
    require(rows, "Empty evidence export")
    return rows


def volume_identity(value, labels):
    require(re.fullmatch(r"[0-9a-f]{64}", value["Name"]), "Invalid daemon-generated volume name")
    require(value["Driver"] == "local" and value["Scope"] == "local" and not value["Options"],
            "Custom volume driver/options/scope not admitted")
    require(value["Labels"] == labels and value["CreatedAt"], "Volume ticket/nonce mismatch")
    return {key: value[key] for key in ("Name", "Driver", "Scope", "Labels", "Options", "CreatedAt")}


def container_identity(value, labels, image_id, volume, source, recipe):
    require(re.fullmatch(r"[0-9a-f]{64}", value["Id"]), "Invalid container ID")
    config, host = value["Config"], value["HostConfig"]
    require({key: value for key, value in config["Labels"].items() if key.startswith("jsti.registry.")} == labels
            and config["Image"] == IMAGE and value["Image"] == image_id,
            "Container ticket/nonce/image mismatch")
    require(config["Cmd"] == ["bash", "/recipe/registry-linux-supported-fs-container.sh"] and
            config["User"] == "", "Unexpected container command/user")
    require(host["Memory"] == MEMORY and host["MemorySwap"] == MEMORY and
            host["NetworkMode"] == "none" and not host["Privileged"] and not host["AutoRemove"] and
            not host.get("UsernsMode") and not host.get("CapAdd") and not host.get("SecurityOpt") and
            not host.get("Devices") and not host.get("DeviceRequests"), "Unsafe container configuration")
    mounts = value["Mounts"]
    require(len(mounts) == 3, "Unexpected container mounts")
    actual = {m["Destination"]: m for m in mounts}
    require(set(actual) == {"/jsti-qualified", "/source", "/recipe"}, "Unexpected mount destinations")
    require(actual["/jsti-qualified"]["Type"] == "volume" and
            actual["/jsti-qualified"]["Name"] == volume and actual["/jsti-qualified"]["RW"],
            "Wrong managed volume")
    for target, path in (("/source", source), ("/recipe", recipe)):
        require(actual[target]["Type"] == "bind" and actual[target]["Source"] == str(path)
                and actual[target]["RW"] is False, "Readonly binding mismatch")
    return {"Id": value["Id"], "Image": value["Image"], "Config": config, "HostConfig": host,
            "Mounts": mounts}


def qualification_status(folder, container_exit):
    status = load(folder / "qualification-status.json")
    require(set(status) == {"nativeExit", "capabilityGateExit", "swiftExit", "lockExit"},
            "Incomplete qualification status")
    require(all(type(value) is int for value in status.values()), "An execution stage was unreached")
    require(load(folder / "native.command.json")["exit"] == status["nativeExit"], "Native status mismatch")
    require(load(folder / "swift.command.json")["exit"] == status["swiftExit"], "Swift status mismatch")
    require(status["nativeExit"] == status["capabilityGateExit"] == status["swiftExit"]
            == status["lockExit"] == container_exit == 0, "Native/gate/Swift/lock/container failure")
    require(load(folder / "resources.command.json")["exit"] == 0, "Resource admission failed")
    capacity, memory = [json.loads(row) for row in (folder / "resources.stdout.log").read_text().splitlines()]
    require(capacity["availableBytes"] >= 12 * 1024**3 and capacity["availableInodes"] >= 100000 and
            memory["memoryBytes"] == MEMORY and memory["swapBytes"] == 0, "Resource observation not admitted")
    require(sha(folder / "root-lock.before.raw") == sha(folder / "root-lock.after.raw"),
            "Apple lockfile preservation not proven")
    return native_gate((folder / "native.stdout.log").read_text(),
                       (folder / "native.stderr.log").read_text(), status["nativeExit"])


def killed_or_timed_out(status):
    return status == 124 or status < 0 or 128 < status <= 192


def retired_command(record, label):
    require(isinstance(record, dict) and type(record.get("exit")) is int,
            "Missing/malformed command exit: " + label)
    flags = ("timeoutOrKilled", "outerDeadlineExceeded", "processJoinUnconfirmed")
    require(all(type(record.get(key)) is bool for key in flags),
            "Missing/malformed command retirement flags: " + label)
    require(not killed_or_timed_out(record["exit"]) and not any(record[key] for key in flags),
            "Command timed out, killed or retirement unconfirmed: " + label)
    return record["exit"]


def load_retirement(path):
    def unique(pairs):
        value = dict(pairs)
        require(len(value) == len(pairs), "Duplicate retirement metadata key: " + str(path))
        return value
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"), object_pairs_hook=unique)


def exported_retirement(folder, container_exit):
    status = load_retirement(folder / "qualification-status.json")
    stages = {"nativeExit": "native", "capabilityGateExit": "capability-gate",
              "swiftExit": "swift", "lockExit": "restore-lock"}
    require(isinstance(status, dict) and set(status) == set(stages) and
            all(value is None or type(value) is int for value in status.values()),
            "Missing/malformed stage retirement statuses")
    records = {}
    for path in sorted(folder.glob("*.command.json")):
        label = path.name.removesuffix(".command.json")
        records[label] = retired_command(load_retirement(path), label)
    required = {"recipe-binding", "actual-head", "actual-tree", "readonly-status", "copy-source",
                "private-ownership", "dropped-process", "identity", "resources", "final-status"}
    require(required <= set(records), "Required command retirement evidence missing: " +
            ", ".join(sorted(required - set(records))))
    for key, label in stages.items():
        if status[key] is None:
            require(label not in records, "Unreached stage has command evidence: " + label)
        else:
            require(label in records and records[label] == status[key],
                    "Required stage retirement evidence missing/mismatched: " + label)
    require(records["dropped-process"] == container_exit, "Dropped-process/container status mismatch")
    require(records["final-status"] == (0 if all(value == 0 for value in status.values()) else 1),
            "Final status command outcome mismatch")
    return {"removalAdmitted": True, "commandExits": records, "stageExits": status}


def host():
    temp = pathlib.Path(os.environ["RUNNER_TEMP"])
    require(temp.is_dir() and not temp.is_symlink() and temp.resolve() == temp, "Unsafe runner temp")
    out = pathlib.Path(os.environ["JSTI_SUPPORTED_FS_EVIDENCE"])
    require(out.parent == temp and out.name == "jsti-registry-supported-" +
            os.environ["GITHUB_RUN_ID"] + "-" + os.environ["GITHUB_RUN_ATTEMPT"], "Wrong evidence root")
    out.mkdir(mode=0o700)
    ticket = os.environ["GITHUB_RUN_ID"] + "." + os.environ["GITHUB_RUN_ATTEMPT"]
    nonce = secrets.token_hex(32)
    labels = {"jsti.registry.ticket": ticket, "jsti.registry.nonce": nonce,
              "jsti.registry.purpose": "supported-fs-qualification"}
    state = {"labels": labels, "image": IMAGE, "volume": None, "container": None,
             "volumeOwned": False, "containerOwned": False, "exported": False,
             "containerRemoved": False, "volumeRemoved": False, "stopExit": None,
             "waitRPCExit": None, "containerExit": None, "attachExit": None,
             "qualificationStatuses": None, "qualificationObservation": "unreached-before-start",
             "diskQuota": "waived-only-on-exclusive-disposable-GitHub-hosted-VM",
             "allocationUncertain": False, "errors": []}
    save(out / "resource-ticket.json", state)
    sequence = 0

    def command(label, seconds, argv, required=True):
        nonlocal sequence, retained_for_error
        sequence += 1
        label = str(sequence).zfill(2) + "-" + label
        result = run(out, label, seconds, argv)
        data = (out / (label + ".stdout.log")).read_bytes()
        try:
            retired_command(load_retirement(out / (label + ".command.json")), label)
        except ValueError as error:
            retained_for_error = True
            state["errors"].append("Host command retirement: " + str(error))
            if required:
                raise
        if required:
            require(result == 0, "Command failed: " + label + " exit=" + str(result))
        return result, data

    docker = shutil.which("docker")
    result = 1
    retained_for_error = False
    source = recipe = image_id = volume_proof = container_proof = None
    try:
        require(os.environ.get("GITHUB_ACTIONS") == "true" and
                os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted" and
                os.environ.get("RUNNER_OS") == "Linux" and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch",
                "Exclusive disposable GitHub-hosted Ubuntu manual job required; never local/self-hosted")
        require(docker, "Docker unavailable")
        require(not any(os.environ.get(key) for key in
                        ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH")),
                "Remote/custom Docker endpoint not admitted")
        config = out / "docker-config"
        config.mkdir(mode=0o700)
        os.environ["DOCKER_CONFIG"] = str(config)
        tools = (("docker", docker), ("python", sys.executable),
                 ("timeout", shutil.which("timeout")), ("git", shutil.which("git")))
        require(all(path for _, path in tools), "Required host tool missing")
        save(out / "host-tools.json", {
            name: {"resolved": str(pathlib.Path(path).resolve()), "sha256": sha(path)}
            for name, path in tools
        })
        source = pathlib.Path(os.environ["GITHUB_WORKSPACE"])
        require(source.resolve() == source and source.is_dir() and not source.is_symlink(), "Unsafe checkout")
        head = os.environ["EXPECTED_HEAD"]
        require(re.fullmatch(r"[0-9a-f]{40}", head), "Invalid expected HEAD")
        git = ["git", "--git-dir=" + str(source / ".git"), "--work-tree=" + str(source)]
        _, actual_head = command("head", 30, [*git, "rev-parse", "HEAD"])
        require(actual_head.decode().strip() == head, "Checkout HEAD mismatch")
        _, actual_tree = command("tree", 30, [*git, "rev-parse", "HEAD^{tree}"])
        tree = actual_tree.decode().strip()
        require(re.fullmatch(r"[0-9a-f]{40}", tree), "Invalid tree")
        _, dirty = command("status", 30, [*git, "status", "--porcelain=v1", "-z", "--untracked-files=all"])
        require(not dirty, "Checkout not clean")
        _, paths = command("tracked", 30, [*git, "ls-files", "-z"])
        _, entries = command("entries", 30, [*git, "ls-tree", "-r", "-z", "HEAD"])
        recipe = out / "recipe"
        recipe.mkdir(mode=0o700)
        (recipe / "tracked.nul").write_bytes(paths)
        (recipe / "tree.nul").write_bytes(entries)
        gate = str(pathlib.Path(__file__).resolve())
        command("source-plan", 120, [sys.executable, gate, "plan", str(source),
                                    str(recipe / "tracked.nul"), str(recipe / "tree.nul"),
                                    str(recipe / "source-plan.json")])
        for name in RECIPES:
            original = source / "scripts" / name
            require(original.is_file() and not original.is_symlink(), "Unsafe recipe")
            shutil.copyfile(original, recipe / name)
        binding = {"head": head, "tree": tree, "rootLockSHA256": sha(source / "Package.resolved"),
                   "recipeSHA256": {name: sha(recipe / name) for name in RECIPES},
                   "manifestSHA256": {name: sha(recipe / name) for name in
                                      ("tracked.nul", "tree.nul", "source-plan.json")}}
        save(recipe / "binding.json", binding)
        # The host ancestor stays private; the read-only bind must be readable after dropping UID.
        for path in recipe.iterdir():
            path.chmod(0o644)
        recipe.chmod(0o755)
        command("docker-version", 30, [docker, "version"])
        command("docker-info", 30, [docker, "info", "--format",
                                  '{"Driver":{{json .Driver}},"CgroupVersion":{{json .CgroupVersion}}}'])
        command("pull", 300, [docker, "pull", IMAGE])
        _, raw = command("image", 30, [docker, "image", "inspect", IMAGE])
        image = json.loads(raw)[0]
        require(IMAGE.split("@", 1)[1] in [value.split("@")[-1] for value in image["RepoDigests"]],
                "Pinned image digest not observed")
        image_id = image["Id"]
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", image_id), "Invalid image identity")
        label_args = [argument for key, value in labels.items() for argument in ("--label", key + "=" + value)]
        status, raw = command("volume-create", 30, [docker, "volume", "create", "--driver", "local", *label_args], False)
        state["volume"] = raw.decode().strip()
        if status or not re.fullmatch(r"[0-9a-f]{64}", state["volume"]):
            state["allocationUncertain"] = True
        require(status == 0 and re.fullmatch(r"[0-9a-f]{64}", state["volume"]), "Volume allocation uncertain")
        _, raw = command("volume-inspect", 15, [docker, "volume", "inspect", state["volume"]])
        volume_proof = volume_identity(json.loads(raw)[0], labels)
        require(volume_proof["Name"] == state["volume"], "Returned volume identity mismatch")
        state["volumeOwned"] = True
        status, raw = command("create", 30, [docker, "create", "--init", "--network", "none",
            "--memory", str(MEMORY), "--memory-swap", str(MEMORY), *label_args,
            "--mount", "type=volume,source=" + state["volume"] + ",target=/jsti-qualified,volume-nocopy",
            "--mount", "type=bind,source=" + str(source) + ",target=/source,readonly",
            "--mount", "type=bind,source=" + str(recipe) + ",target=/recipe,readonly",
            "--env", "EXPECTED_HEAD=" + head, "--env", "EXPECTED_TREE=" + tree,
            IMAGE, "bash", "/recipe/registry-linux-supported-fs-container.sh"], False)
        state["container"] = raw.decode().strip()
        if status or not re.fullmatch(r"[0-9a-f]{64}", state["container"]):
            state["allocationUncertain"] = True
        require(status == 0 and re.fullmatch(r"[0-9a-f]{64}", state["container"]), "Container allocation uncertain")
        _, raw = command("inspect-created", 15, [docker, "inspect", state["container"]])
        value = json.loads(raw)[0]
        container_proof = container_identity(value, labels, image_id, state["volume"], source, recipe)
        require(value["Id"] == state["container"] and value["State"]["Status"] == "created"
                and not value["State"]["Running"] and "EXPECTED_HEAD=" + head in value["Config"]["Env"]
                and "EXPECTED_TREE=" + tree in value["Config"]["Env"], "Unexpected fresh container state/binding")
        state["containerOwned"] = True
        state["qualificationObservation"] = "start-attempted-outcomes-not-yet-observed"
        state["attachExit"], _ = command("start", 1800, [docker, "start", "--attach", state["container"]], False)
        retained_for_error = retained_for_error or killed_or_timed_out(state["attachExit"])
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        state["errors"].append(str(error))
        retained_for_error = True
    finally:
        try:
            if state["containerOwned"]:
                _, raw = command("inspect-stop", 15, [docker, "inspect", state["container"]])
                value = json.loads(raw)[0]
                require(container_identity(value, labels, image_id, state["volume"], source, recipe) == container_proof,
                        "Container authority changed before stop")
                if value["State"]["Running"]:
                    state["stopExit"], _ = command("stop", 30, [docker, "stop", "--time", "10", state["container"]])
                else:
                    state["stopNotNeededAlreadyStopped"] = True
                state["waitRPCExit"], raw = command("wait", 15, [docker, "wait", state["container"]])
                require(re.fullmatch(rb"\d+\n?", raw), "Invalid container exit observation")
                state["containerExit"] = int(raw)
                if state["attachExit"] != state["containerExit"]:
                    retained_for_error = True
                _, raw = command("inspect-joined", 15, [docker, "inspect", state["container"]])
                value = json.loads(raw)[0]
                require(container_identity(value, labels, image_id, state["volume"], source, recipe) == container_proof,
                        "Container authority changed after join")
                observed = value["State"]
                state["joinedState"] = observed
                if observed.get("OOMKilled") is not False:
                    retained_for_error = True
                    state["errors"].append("Container OOM retirement observation true or unavailable")
                require(observed["Status"] == "exited" and not any(observed[key] for key in
                        ("Running", "Paused", "Restarting", "Dead")) and observed["Pid"] == 0 and
                        observed["ExitCode"] == state["containerExit"], "Stopped-state proof missing")
                exported = out / "export"
                exported.mkdir(mode=0o700)
                command("export", 120, [docker, "cp", state["container"] + ":/jsti-qualified/evidence/.", str(exported)])
                save(out / "export-manifest.json", export_manifest(exported))
                state["exported"] = True
                try:
                    state["retirementEvidence"] = exported_retirement(exported, state["containerExit"])
                    save(out / "host-retirement-gate.json", state["retirementEvidence"])
                except (ValueError, OSError, KeyError) as error:
                    retained_for_error = True
                    state["retirementEvidence"] = {"removalAdmitted": False, "error": str(error)}
                    state["errors"].append("Exported command retirement: " + str(error))
                try:
                    state["qualificationStatuses"] = load(exported / "qualification-status.json")
                    state["qualificationObservation"] = "exported-stage-statuses"
                    require(state["retirementEvidence"]["removalAdmitted"],
                            "Qualification retirement evidence not admitted")
                    capability = qualification_status(exported, state["containerExit"])
                    require(sha(exported / "root-lock.after.raw") == binding["rootLockSHA256"],
                            "Exported lock differs from the frozen source lock")
                    save(out / "host-capability-gate.json", capability)
                    require(state["attachExit"] == 0, "Attach process failed")
                    result = 0
                except json.JSONDecodeError as error:
                    state["errors"].append("Qualification metadata malformed: " + str(error))
                    retained_for_error = True
                except ValueError as error:
                    state["errors"].append("Qualification failed: " + str(error))
                except (OSError, KeyError) as error:
                    state["errors"].append("Qualification metadata unavailable: " + str(error))
                    retained_for_error = True
                if not retained_for_error:
                    _, raw = command("inspect-remove", 15, [docker, "inspect", state["container"]])
                    value = json.loads(raw)[0]
                    require(container_identity(value, labels, image_id, state["volume"], source, recipe) == container_proof
                            and value["State"] == observed, "Final stopped container proof changed")
                    _, raw = command("volume-before-remove", 15, [docker, "volume", "inspect", state["volume"]])
                    require(volume_identity(json.loads(raw)[0], labels) == volume_proof, "Volume authority changed")
                    command("remove", 30, [docker, "rm", state["container"]])
                    state["containerRemoved"] = True
                    _, referenced = command("volume-references", 15, [docker, "ps", "-aq", "--filter",
                                                                    "volume=" + state["volume"]])
                    require(not referenced.strip(), "Volume still referenced; retain")
                    _, raw = command("volume-final", 15, [docker, "volume", "inspect", state["volume"]])
                    require(volume_identity(json.loads(raw)[0], labels) == volume_proof, "Volume ticket changed")
                    command("volume-remove", 30, [docker, "volume", "rm", state["volume"]])
                    state["volumeRemoved"] = True
        except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
            state["errors"].append("Cleanup/export authority gap: " + str(error))
            result = 1
        state["resourcesRetained"] = bool(state["volume"] and not state["volumeRemoved"]) or state["allocationUncertain"]
        if retained_for_error or state["resourcesRetained"]:
            result = 1
        state["hostExit"] = result
        save(out / "host-result.json", state)
        print(json.dumps(state))
    return result


def main():
    action, *args = sys.argv[1:]
    if action == "host":
        return host()
    if action == "run":
        folder, label, seconds, separator, *command = args
        require(separator == "--" and command and 0 < int(seconds) <= 1800, "Invalid finite command")
        return run(folder, label, int(seconds), command)
    if action == "plan":
        source, listing, tree, output = args
        save(output, source_plan(source, listing, tree))
    elif action == "copy":
        source, destination, plan, output = args
        save(output, copy_source(source, destination, load(plan)))
    elif action == "resources":
        resources(args[0])
    elif action == "native":
        stdout, stderr, status, output = args
        save(output, native_gate(pathlib.Path(stdout).read_text(), pathlib.Path(stderr).read_text(), int(status)))
    elif action == "status":
        output, native, gate, swift, lock = args
        statuses = {name: None if value == "unreached" else int(value) for name, value in
                    zip(("nativeExit", "capabilityGateExit", "swiftExit", "lockExit"), (native, gate, swift, lock))}
        save(output, statuses)
        return 0 if all(type(value) is int and value == 0 for value in statuses.values()) else 1
    else:
        raise ValueError("Unknown qualification action")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        print("ENVIRONMENT_NOT_ADMITTED: " + str(error), file=sys.stderr)
        sys.exit(78)
