#!/usr/bin/env python3
"""Create a fresh CI simulator matching the old selector; remove only our UUID."""

import argparse
import json
from pathlib import Path
import subprocess
import uuid


def run(*arguments):
    return subprocess.run(["xcrun", "simctl", *arguments], check=True, capture_output=True,
                          text=True, timeout=60).stdout.strip()


def devices(available=True):
    arguments = ("list", "devices", "available", "-j") if available else ("list", "devices", "-j")
    return json.loads(run(*arguments))["devices"]


def selected_configuration(inventory):
    candidates = [(runtime, device) for runtime, values in inventory.items() for device in values
                  if device.get("isAvailable") and device.get("name", "").startswith("iPhone")]
    preferred = [item for item in candidates if item[1]["name"] == "iPhone 17 Pro"]
    if not candidates:
        raise ValueError("No available iPhone simulator configuration")
    runtime, device = (preferred or candidates)[0]
    device_type = device.get("deviceTypeIdentifier")
    if not runtime or not device_type:
        raise ValueError("Selected simulator does not identify its exact runtime and device type")
    return runtime, device_type


def remove_owned(identifier):
    uuid.UUID(identifier)
    # Cleanup must include unavailable devices; only configuration selection
    # filters for availability. Never mutate another UUID from this inventory.
    state = next((device.get("state") for values in devices(available=False).values() for device in values
                  if device.get("udid") == identifier), None)
    if state is None:
        return {"createdUUID": identifier, "status": "already_absent", "verifiedAbsent": True}
    shutdown_failure = None
    if state != "Shutdown":
        try:
            run("shutdown", identifier)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            # State can race to Shutdown. Safe deletion still targets only our
            # device; actual absence, not shutdown's exit status, decides cleanup.
            shutdown_failure = type(error).__name__
    run("delete", identifier)
    if any(device.get("udid") == identifier for values in devices(available=False).values() for device in values):
        raise RuntimeError(f"Owned simulator {identifier} still exists after deletion")
    return {"createdUUID": identifier, "status": "deleted", "verifiedAbsent": True,
            "shutdownWarning": shutdown_failure}


def create(receipt, environment, owner):
    try:
        receipt.lstat()
    except FileNotFoundError:
        pass
    else:
        raise ValueError("Refusing an existing ownership receipt before creating a device")
    # Ownership admission includes unavailable pre-existing UUIDs; the
    # configuration selector still considers only available iPhones.
    inventory = devices(available=False)
    runtime, device_type = selected_configuration(inventory)
    previous = {device["udid"] for values in inventory.values() for device in values}
    identifier = run("create", f"JSTI owned CI {uuid.uuid4()}", device_type, runtime)
    uuid.UUID(identifier)
    if identifier in previous:
        raise ValueError("Creation returned a pre-existing device; it is not owned and will not be touched")
    record = {"version": 1, "owner": owner, "createdUUID": identifier,
              "runtime": runtime, "deviceType": device_type}
    try:
        # Exclusive receipt creation refuses stale ownership rather than replacing it.
        with receipt.open("x") as output:
            json.dump(record, output)
            output.write("\n")
        actual = [(key, device) for key, values in devices().items() for device in values
                  if device.get("udid") == identifier]
        if len(actual) != 1 or actual[0][0] != runtime or actual[0][1].get("deviceTypeIdentifier") != device_type:
            raise ValueError("The newly created simulator does not match the selected configuration")
        with environment.open("a") as output:
            output.write(f"SIMULATOR_ID={identifier}\nOWNED_IOS_SIMULATOR_RECEIPT={receipt}\n")
    except BaseException:
        remove_owned(identifier)
        raise
    print(f"Created owned iOS Simulator {identifier}: {device_type}, {runtime}")


def cleanup(receipt, owner):
    try:
        record = json.loads(receipt.read_text())
    except FileNotFoundError:
        return
    if (record.get("version") != 1 or record.get("owner") != owner
            or not record.get("runtime") or not record.get("deviceType")):
        raise ValueError("Invalid owned simulator receipt")
    try:
        record["cleanup"] = remove_owned(record["createdUUID"])
    except BaseException as error:
        record["cleanup"] = {"createdUUID": record["createdUUID"], "status": "failed",
                             "verifiedAbsent": False, "error": type(error).__name__}
        receipt.write_text(json.dumps(record, indent=2) + "\n")
        raise
    receipt.write_text(json.dumps(record, indent=2) + "\n")
    print(f"Owned simulator cleanup: {json.dumps(record['cleanup'], sort_keys=True)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("create", "cleanup"))
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--github-env", type=Path)
    parser.add_argument("--owner", required=True)
    arguments = parser.parse_args()
    if arguments.operation == "create":
        if arguments.github_env is None:
            parser.error("create requires --github-env")
        create(arguments.receipt, arguments.github_env, arguments.owner)
    else:
        cleanup(arguments.receipt, arguments.owner)


if __name__ == "__main__":
    main()
