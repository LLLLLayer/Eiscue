#!/usr/bin/env python3
"""Loopback lifecycle checks; the fixture never calls a model or external host."""
import importlib.util
from pathlib import Path
import socket
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "run-with-model-fixture.py"
spec = importlib.util.spec_from_file_location("fixture_runner", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ModelFixtureRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.log = Path(self.temporary.name) / "fixture.log"
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            self.port = reservation.getsockname()[1]

    def assert_stopped(self):
        with socket.socket() as connection:
            self.assertNotEqual(connection.connect_ex(("127.0.0.1", self.port)), 0)
        self.assertIn("intentional_shutdown=True", self.log.read_text())

    def test_ready_before_command_and_stopped_after_success(self):
        command = [sys.executable, "-c", "import os, urllib.request; "
                   f"assert os.environ['TEST_RUNNER_EISCUE_TEST_MODEL_PORT'] == '{self.port}'; "
                   f"assert os.environ['EISCUE_TEST_MODEL_PORT'] == '{self.port}'; "
                   f"assert urllib.request.urlopen('http://127.0.0.1:{self.port}/').read() == b'fixture ready'"]
        self.assertEqual(runner.run(self.log, command, self.port), 0)
        self.assert_stopped()

    def test_preserves_command_failure_and_stops_fixture(self):
        self.assertEqual(runner.run(self.log, [sys.executable, "-c", "raise SystemExit(19)"], self.port), 19)
        self.assert_stopped()

    def test_refuses_occupied_port_without_stopping_its_owner(self):
        with socket.socket() as other_server:
            other_server.bind(("127.0.0.1", self.port))
            other_server.listen()
            with self.assertRaisesRegex(ValueError, "in use"):
                runner.run(self.log, [sys.executable, "-c", "pass"], self.port)
            with socket.socket() as probe:
                self.assertEqual(probe.connect_ex(("127.0.0.1", self.port)), 0)
        self.assertFalse(self.log.exists())

    def test_refuses_to_overwrite_a_previous_lifecycle_log(self):
        self.log.write_text("previous evidence")
        with self.assertRaises(FileExistsError):
            runner.run(self.log, [sys.executable, "-c", "pass"], self.port)
        self.assertEqual(self.log.read_text(), "previous evidence")


if __name__ == "__main__":
    unittest.main()
