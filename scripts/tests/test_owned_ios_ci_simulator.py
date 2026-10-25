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
            self.assertEqual(environment.read_text(),
                             f"SIMULATOR_ID={NEW}\nOWNED_IOS_SIMULATOR_RECEIPT={receipt}\n")
            self.assertNotIn(OLD, receipt.read_text())
            self.assertEqual(json.loads(receipt.read_text())["createdUUID"], NEW)

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
