"""Offline tests with fake pairing commands and the shell's metadata-only mode.

No device, Keychain, Cargo build or network is used.
"""

import importlib.util
import io
import json
from pathlib import Path
import signal
import stat
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "setup-device.py"
SPEC = importlib.util.spec_from_file_location("setup_device", SCRIPT)
helper = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = helper
SPEC.loader.exec_module(helper)


def device(number=1, *, transport="wired", reality="physical", kind="iPhone"):
    return {
        "identifier": f"00000000-0000-4000-8000-{number:012d}",
        "hardwareProperties": {"udid": f"00000000-{number:016d}", "reality": reality,
                               "deviceType": kind, "platform": "iOS"},
        "deviceProperties": {"name": f"Test phone {number}", "developerModeStatus": "enabled",
                             "ddiServicesAvailable": True},
        "connectionProperties": {"transportType": transport, "pairingState": "paired"},
    }


class FakeCommands:
    def __init__(self, records=None, *, pending=False, fail_pair=False, fail_copy=False, interrupt_pair=False,
                 tool_schemas=(1,), output_version=1):
        self.records = records if records is not None else [device()]
        self.pending = pending
        self.fail_pair = fail_pair
        self.fail_copy = fail_copy
        self.interrupt_pair = interrupt_pair
        self.tool_schemas = tool_schemas
        self.output_version = output_version
        self.calls = []
        self.temporary = None
        self.identity = None
        self.directory_mode = None
        self.file_mode = None

    def __call__(self, arguments, **_options):
        self.calls.append(arguments)
        if arguments[0] == "/bin/bash":
            if arguments[-1] == "--describe-format":
                return json.dumps({"protocolVersion": 1, "identitySchemaVersions": self.tool_schemas})
            self.identity = Path(arguments[arguments.index("--output") + 1])
            self.identity.write_text(json.dumps({"version": self.output_version, "synthetic": "not a credential"}), encoding="utf-8")
            self.identity.chmod(0o600)
            if self.interrupt_pair:
                raise KeyboardInterrupt()
            if self.fail_pair:
                raise helper.SetupError("Synthetic pairing failure")
            return "suppressed fixture output"
        output = Path(arguments[arguments.index("--json-output") + 1])
        self.temporary = output.parent
        self.directory_mode = stat.S_IMODE(self.temporary.stat().st_mode)
        if arguments[2:4] == ["list", "devices"]:
            result = {"devices": self.records}
        elif arguments[2:5] == ["device", "info", "files"]:
            udid = arguments[arguments.index("--device") + 1]
            selected = next(record for record in self.records if record["hardwareProperties"]["udid"] == udid)
            result = {"deviceIdentifier": selected["identifier"], "domain": "appDataContainer",
                      "domainIdentifier": "org.eiscue.app",
                      "files": [{"name": helper.TRANSFER_NAME}] if self.pending else []}
        elif arguments[2:5] == ["device", "copy", "to"]:
            self.file_mode = stat.S_IMODE(self.identity.stat().st_mode)
            if self.fail_copy:
                raise helper.SetupError("Synthetic transfer failure")
            result = {}
        else:
            raise AssertionError(f"Unexpected fake subprocess: {arguments}")
        output.write_text(json.dumps({"info": {"outcome": "success"}, "result": result}), encoding="utf-8")
        return ""

    @property
    def copies(self):
        return [call for call in self.calls if call[2:5] == ["device", "copy", "to"]]


class SetupDeviceTests(unittest.TestCase):
    def run_setup(self, runner, responses=("1", "yes"), **options):
        answers = iter(responses)
        with patch.object(helper, "preflight"):
            helper.setup(run=runner, ask=lambda _: next(answers), write=lambda _: None, **options)

    def test_candidates_are_real_wired_phones_or_ipads(self):
        candidates = [device(), device(2, kind="iPad"), device(3, transport="localNetwork"),
                      device(4, reality="simulated"), device(5, kind="appleWatch")]
        self.assertEqual([item.udid for item in helper.usb_devices({"devices": candidates})],
                         [candidates[0]["hardwareProperties"]["udid"], candidates[1]["hardwareProperties"]["udid"]])
        duplicate = [device(), device()]
        with self.assertRaises(helper.SetupError):
            helper.usb_devices({"devices": duplicate})

    def test_selection_has_no_default_even_for_one_device(self):
        answers = iter(["", "0", "1"])
        prompts = []
        selected = helper.choose_device(helper.usb_devices({"devices": [device()]}),
                                        ask=lambda prompt: (prompts.append(prompt), next(answers))[1],
                                        write=lambda _: None)
        self.assertEqual(selected.udid, device()["hardwareProperties"]["udid"])
        self.assertEqual(len(prompts), 3)
        with self.assertRaises(helper.SetupCancelled):
            helper.choose_device([selected], ask=lambda _: "q", write=lambda _: None)

    def test_selected_device_is_same_for_pair_and_transfer_and_secrets_are_cleaned(self):
        runner = FakeCommands([device(), device(2)])
        self.run_setup(runner, ("2", "yes"))
        pair = next(call for call in runner.calls if "--udid" in call)
        copy = runner.copies[0]
        selected_udid = device(2)["hardwareProperties"]["udid"]
        self.assertEqual(pair[pair.index("--udid") + 1], selected_udid)
        self.assertIn("--enable-wifi", pair)
        self.assertEqual(pair[pair.index("--identity-schema-version") + 1], "1")
        self.assertEqual(copy[copy.index("--device") + 1], selected_udid)
        self.assertEqual(copy[copy.index("--domain-identifier") + 1], "org.eiscue.app")
        self.assertEqual(copy[copy.index("--destination") + 1], "tmp/EiscuePairingTransfer.json")
        self.assertEqual(runner.directory_mode, 0o700)
        self.assertEqual(runner.file_mode, 0o600)
        self.assertFalse(runner.temporary.exists())

    def test_legacy_command_keeps_v1_even_when_tool_supports_newer_format(self):
        runner = FakeCommands(tool_schemas=(1, 2))
        self.run_setup(runner)
        pair = next(call for call in runner.calls if "--udid" in call)
        self.assertEqual(pair[pair.index("--identity-schema-version") + 1], "1")
        self.assertEqual(len(runner.copies), 1)

    def test_incompatible_or_invalid_capabilities_stop_before_device_access(self):
        for schemas in ((2,), (), (True,), ("1",)):
            with self.subTest(schemas=schemas):
                runner = FakeCommands(tool_schemas=schemas)
                with self.assertRaises(helper.SetupError):
                    self.run_setup(runner, app_schemas=(1,))
                self.assertEqual(len(runner.calls), 1)
                self.assertEqual(runner.calls[0][-1], "--describe-format")
                self.assertIsNone(runner.identity)

    def test_unexpected_export_schema_is_never_transferred_and_is_cleaned(self):
        for version in (2, True, None, "1"):
            with self.subTest(version=version):
                runner = FakeCommands(output_version=version)
                with self.assertRaisesRegex(helper.SetupError, "format accepted"):
                    self.run_setup(runner, app_schemas=(1,))
                self.assertFalse(runner.copies)
                self.assertFalse(runner.identity.exists())
                self.assertFalse(runner.temporary.exists())

    def test_app_schema_argument_is_forwarded_and_unknown_cli_options_do_not_pair(self):
        with patch.object(helper, "setup") as setup:
            self.assertEqual(helper.main(["--app-pairing-schema", "1"]), 0)
            setup.assert_called_once_with(app_schemas=[1])
        with patch.object(helper, "setup") as setup, patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as result:
                helper.main(["--app-pairing-schema", "0"])
            self.assertEqual(result.exception.code, 2)
            setup.assert_not_called()

    def test_shell_format_metadata_and_unknown_version_need_no_external_tools(self):
        script = SCRIPT.with_name("pair-device-usb.sh")
        capability = subprocess.run(["/bin/bash", str(script), "--describe-format"],
                                    env={"PATH": ""}, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(capability.stdout), {"protocolVersion": 1, "identitySchemaVersions": [1]})
        rejected = subprocess.run(["/bin/bash", str(script), "--identity-schema-version", "2"],
                                  env={"PATH": ""}, capture_output=True, text=True)
        self.assertEqual(rejected.returncode, 2)
        self.assertIn("Unsupported pairing identity format", rejected.stderr)

    def test_existing_transfer_and_unprepared_device_never_generate_identity(self):
        for runner in (FakeCommands(pending=True), FakeCommands()):
            with self.subTest(pending=runner.pending):
                if not runner.pending:
                    runner.records[0]["deviceProperties"]["ddiServicesAvailable"] = False
                with self.assertRaises(helper.SetupError):
                    self.run_setup(runner)
                self.assertIsNone(runner.identity)
                self.assertFalse(runner.copies)
                self.assertFalse(runner.temporary.exists())

    def test_pair_failure_never_transfers_and_every_exit_removes_private_file(self):
        for options, expected in (({"fail_pair": True}, helper.SetupError),
                                  ({"fail_copy": True}, helper.SetupError),
                                  ({"interrupt_pair": True}, KeyboardInterrupt)):
            with self.subTest(options=options):
                runner = FakeCommands(**options)
                with self.assertRaises(expected):
                    self.run_setup(runner)
                self.assertFalse(runner.identity.exists())
                self.assertFalse(runner.temporary.exists())
                self.assertEqual(len(runner.copies), int(options.get("fail_copy", False)))

    def test_command_interrupt_terminates_owned_child_group_before_propagating(self):
        process = Mock(pid=12345)
        process.poll.return_value = None
        process.communicate.side_effect = KeyboardInterrupt()
        process.wait.side_effect = [subprocess.TimeoutExpired("synthetic", 5), 0]
        with patch.object(helper.subprocess, "Popen", return_value=process) as popen, \
                patch.object(helper.os, "killpg") as killpg:
            with self.assertRaises(KeyboardInterrupt):
                helper.run_command(["synthetic-command"], failure="Synthetic failure")
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertEqual(popen.call_args.kwargs["env"]["EISCUE_RUST_TOOLCHAIN"], "1.96.0")
        self.assertEqual(killpg.call_args_list[0].args, (12345, signal.SIGTERM))
        self.assertEqual(killpg.call_args_list[1].args, (12345, signal.SIGKILL))
        self.assertEqual(process.wait.call_count, 2)

    def test_finished_group_leader_does_not_leave_descendants_running(self):
        process = Mock(pid=12345)
        process.poll.return_value = 0
        process.wait.return_value = 0
        with patch.object(helper.os, "killpg") as killpg:
            helper.stop_process_group(process)
        self.assertEqual([call.args for call in killpg.call_args_list],
                         [(12345, signal.SIGTERM), (12345, signal.SIGKILL)])
        self.assertEqual(process.wait.call_count, 2)

    def test_help_does_not_start_setup(self):
        with patch.object(helper, "setup") as setup, patch("sys.stdout", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as result:
                helper.main(["--help"])
        self.assertEqual(result.exception.code, 0)
        setup.assert_not_called()


if __name__ == "__main__":
    unittest.main()
