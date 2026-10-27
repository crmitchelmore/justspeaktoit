import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "owned_simulator", Path(__file__).resolve().parents[1] / "owned-ios-ci-simulator.py")
owned = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(owned)
OLD = "10000000-0000-0000-0000-000000000001"
NEW = "20000000-0000-0000-0000-000000000002"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"


def inventory(identifier=OLD, name="iPhone 17 Pro", state="Shutdown"):
    return {RUNTIME: [{"name": name, "udid": identifier, "isAvailable": True,
                       "deviceTypeIdentifier": TYPE, "state": state}]}


class OwnedSimulatorTests(unittest.TestCase):
    def test_create_copies_exact_selected_configuration_and_records_only_new_uuid(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt, environment = Path(directory) / "owned.json", Path(directory) / "env"
            after = {RUNTIME: inventory()[RUNTIME] + inventory(NEW)[RUNTIME]}
            with mock.patch.object(owned, "devices", side_effect=[inventory(), after]), \
                    mock.patch.object(owned, "run", return_value=NEW) as run:
                owned.create(receipt, environment, "test-run")
            arguments = run.call_args.args
            self.assertEqual(arguments[0], "create")
            self.assertEqual(arguments[2:], (TYPE, RUNTIME))
            lines = environment.read_text().splitlines()
            self.assertEqual(lines[:2], [f"SIMULATOR_ID={NEW}", f"OWNED_IOS_SIMULATOR_RECEIPT={receipt}"])
            marker = json.loads(lines[2].removeprefix("JSTI_OWNED_SETTINGS_TARGET="))
            self.assertEqual(marker, json.loads(receipt.read_text()))
            self.assertEqual(set(marker), {"version", "owner", "createdUUID", "runtime", "deviceType"})
            self.assertNotIn(OLD, receipt.read_text())
            self.assertEqual(json.loads(receipt.read_text())["createdUUID"], NEW)

    def test_runner_marker_escapes_owner_unicode_and_newline_without_environment_injection(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt, environment = Path(directory) / "owned.json", Path(directory) / "env"
            owner = "123:1:job-é\nINJECTED=1"
            after = {RUNTIME: inventory()[RUNTIME] + inventory(NEW)[RUNTIME]}
            with mock.patch.object(owned, "devices", side_effect=[inventory(), after]), \
                    mock.patch.object(owned, "run", return_value=NEW):
                owned.create(receipt, environment, owner)
            lines = environment.read_text().splitlines()
            self.assertEqual(len(lines), 3)
            marker = json.loads(lines[2].removeprefix("JSTI_OWNED_SETTINGS_TARGET="))
            self.assertEqual(marker["owner"], owner)
            self.assertTrue(lines[2].isascii())
            self.assertNotIn(str(receipt), lines[2])

    def test_missing_exact_device_type_fails_before_creation(self):
        missing = inventory()
        del missing[RUNTIME][0]["deviceTypeIdentifier"]
        with mock.patch.object(owned, "devices", return_value=missing), mock.patch.object(owned, "run") as run:
            with self.assertRaises(ValueError):
                owned.create(Path("unused"), Path("unused"), "test-run")
            run.assert_not_called()

    def test_never_adopts_or_cleans_a_preexisting_returned_uuid(self):
        with mock.patch.object(owned, "devices", return_value=inventory()), \
                mock.patch.object(owned, "run", return_value=OLD) as run:
            with self.assertRaises(ValueError):
                owned.create(Path("unused"), Path("unused"), "test-run")
            self.assertEqual([call.args[0] for call in run.call_args_list], ["create"])

    def test_never_adopts_a_preexisting_unavailable_returned_uuid(self):
        unavailable = inventory(NEW)[RUNTIME][0]
        unavailable["isAvailable"] = False
        before = {RUNTIME: inventory()[RUNTIME] + [unavailable]}
        with tempfile.TemporaryDirectory() as directory:
            receipt, environment = Path(directory) / "owned.json", Path(directory) / "env"
            with mock.patch.object(owned, "devices", return_value=before) as devices, \
                    mock.patch.object(owned, "run", return_value=NEW) as run:
                with self.assertRaises(ValueError):
                    owned.create(receipt, environment, "test-run")
            devices.assert_called_once_with(available=False)
            self.assertEqual([call.args[0] for call in run.call_args_list], ["create"])
            self.assertFalse(receipt.exists())
            self.assertFalse(environment.exists())

    def test_configuration_mismatch_removes_only_new_device(self):
        wrong = inventory(NEW)
        wrong[RUNTIME][0]["deviceTypeIdentifier"] = "different"
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(owned, "devices", side_effect=[inventory(), wrong, wrong, inventory()]), \
                    mock.patch.object(owned, "run", return_value=NEW) as run:
                with self.assertRaises(ValueError):
                    owned.create(Path(directory) / "owned.json", Path(directory) / "env", "test-run")
            self.assertEqual(run.call_args_list[-1].args, ("delete", NEW))
            self.assertFalse(any(OLD in call.args for call in run.call_args_list))

    def test_stale_receipt_is_refused_without_creating_or_deleting_a_device(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "owned.json"
            receipt.write_text("existing receipt")
            with mock.patch.object(owned, "run") as run:
                with self.assertRaises(ValueError):
                    owned.create(receipt, Path(directory) / "env", "test-run")
            self.assertEqual(receipt.read_text(), "existing receipt")
            run.assert_not_called()

    def test_environment_write_failure_cleans_only_the_new_device(self):
        with tempfile.TemporaryDirectory() as directory:
            after = {RUNTIME: inventory()[RUNTIME] + inventory(NEW)[RUNTIME]}
            with mock.patch.object(owned, "devices", side_effect=[inventory(), after, after, inventory()]), \
                    mock.patch.object(owned, "run", return_value=NEW) as run:
                with self.assertRaises(IsADirectoryError):
                    owned.create(Path(directory) / "owned.json", Path(directory), "test-run")
            self.assertEqual(run.call_args_list[-1].args, ("delete", NEW))
            self.assertFalse(any(OLD in call.args for call in run.call_args_list))

    def test_cleanup_shuts_down_then_deletes_only_created_uuid(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "owned.json"
            receipt.write_text(json.dumps({"version": 1, "owner": "test-run", "createdUUID": NEW,
                                           "runtime": RUNTIME, "deviceType": TYPE}))
            with mock.patch.object(owned, "devices", side_effect=[inventory(NEW, state="Booted"), inventory()]), \
                    mock.patch.object(owned, "run") as run:
                owned.cleanup(receipt, "test-run")
            self.assertEqual([call.args for call in run.call_args_list], [("shutdown", NEW), ("delete", NEW)])
            with mock.patch.object(owned, "devices", return_value=inventory()), \
                    mock.patch.object(owned, "run") as run:
                owned.cleanup(receipt, "test-run")
                run.assert_not_called()

    def test_cleanup_still_attempts_owned_delete_after_shutdown_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "owned.json"
            receipt.write_text(json.dumps({"version": 1, "owner": "test-run", "createdUUID": NEW,
                                           "runtime": RUNTIME, "deviceType": TYPE}))
            with mock.patch.object(owned, "devices", side_effect=[inventory(NEW, state="Booted"), inventory()]), \
                    mock.patch.object(owned, "run", side_effect=[subprocess.CalledProcessError(1, ["shutdown", NEW]), ""]) as run:
                owned.cleanup(receipt, "test-run")
            self.assertEqual([call.args for call in run.call_args_list], [("shutdown", NEW), ("delete", NEW)])

    def test_cleanup_rejects_another_job_receipt_before_any_device_command(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "owned.json"
            receipt.write_text(json.dumps({"version": 1, "owner": "another-run", "createdUUID": OLD,
                                           "runtime": RUNTIME, "deviceType": TYPE}))
            with mock.patch.object(owned, "run") as run:
                with self.assertRaises(ValueError):
                    owned.cleanup(receipt, "test-run")
                run.assert_not_called()

    def test_unavailable_owned_device_is_deleted_but_preexisting_unavailable_device_is_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "owned.json"
            receipt.write_text(json.dumps({"version": 1, "owner": "test-run", "createdUUID": NEW,
                                           "runtime": RUNTIME, "deviceType": TYPE}))
            before = {RUNTIME: inventory()[RUNTIME] + inventory(NEW)[RUNTIME]}
            for device in before[RUNTIME]:
                device["isAvailable"] = False
            after = {RUNTIME: [before[RUNTIME][0]]}
            with mock.patch.object(owned, "devices", side_effect=[before, after]) as devices, \
                    mock.patch.object(owned, "run") as run:
                owned.cleanup(receipt, "test-run")
            self.assertEqual(run.call_args_list, [mock.call("delete", NEW)])
            self.assertTrue(all(call.kwargs == {"available": False} for call in devices.call_args_list))
            cleanup = json.loads(receipt.read_text())["cleanup"]
            self.assertTrue(cleanup["verifiedAbsent"])
            self.assertNotIn(OLD, receipt.read_text())

    def test_owned_device_with_missing_or_null_state_is_present_and_must_be_deleted(self):
        for missing in (True, False):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as directory:
                receipt = Path(directory) / "owned.json"
                receipt.write_text(json.dumps({"version": 1, "owner": "test-run", "createdUUID": NEW,
                                               "runtime": RUNTIME, "deviceType": TYPE}))
                before = inventory(NEW)
                if missing:
                    del before[RUNTIME][0]["state"]
                else:
                    before[RUNTIME][0]["state"] = None
                with mock.patch.object(owned, "devices", side_effect=[before, inventory()]), \
                        mock.patch.object(owned, "run") as run:
                    owned.cleanup(receipt, "test-run")
                self.assertEqual([call.args for call in run.call_args_list], [("shutdown", NEW), ("delete", NEW)])
                cleanup = json.loads(receipt.read_text())["cleanup"]
                self.assertEqual(cleanup["status"], "deleted")
                self.assertTrue(cleanup["verifiedAbsent"])

    def test_delete_without_actual_absence_fails_and_records_cleanup_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "owned.json"
            receipt.write_text(json.dumps({"version": 1, "owner": "test-run", "createdUUID": NEW,
                                           "runtime": RUNTIME, "deviceType": TYPE}))
            with mock.patch.object(owned, "devices", return_value=inventory(NEW)), \
                    mock.patch.object(owned, "run"):
                with self.assertRaises(RuntimeError):
                    owned.cleanup(receipt, "test-run")
            self.assertFalse(json.loads(receipt.read_text())["cleanup"]["verifiedAbsent"])

    def test_delete_failure_is_not_hidden_after_shutdown_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "owned.json"
            receipt.write_text(json.dumps({"version": 1, "owner": "test-run", "createdUUID": NEW,
                                           "runtime": RUNTIME, "deviceType": TYPE}))
            failures = [subprocess.CalledProcessError(1, ["shutdown", NEW]),
                        subprocess.CalledProcessError(1, ["delete", NEW])]
            with mock.patch.object(owned, "devices", return_value=inventory(NEW, state="Booted")), \
                    mock.patch.object(owned, "run", side_effect=failures) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    owned.cleanup(receipt, "test-run")
            self.assertEqual([call.args for call in run.call_args_list], [("shutdown", NEW), ("delete", NEW)])
            cleanup = json.loads(receipt.read_text())["cleanup"]
            self.assertEqual(cleanup["status"], "failed")
            self.assertFalse(cleanup["verifiedAbsent"])

    def test_selection_preserves_existing_fallback_without_inventing_a_type(self):
        self.assertEqual(owned.selected_configuration(inventory(name="iPhone 16")), (RUNTIME, TYPE))
        with self.assertRaises(ValueError):
            owned.selected_configuration({})


if __name__ == "__main__":
    unittest.main()
