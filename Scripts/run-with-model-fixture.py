#!/usr/bin/env python3
"""Run a command with an owned loopback model fixture, preserving its exit code."""
import argparse
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request


def run(log_path, command, port=18765):
    if not command:
        raise ValueError("A test command is required after --")
    # Never reuse or stop an existing server: it may belong to another check.
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", port)) == 0:
            raise ValueError(f"Port {port} is in use; run this check after its owner releases the fixture")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("x") as log:
        fixture = subprocess.Popen([sys.executable, str(Path(__file__).with_name("test-model-server.py")), "--port", str(port)],
                                   stdout=log, stderr=subprocess.STDOUT)
        result = 2
        try:
            for _ in range(100):
                if fixture.poll() is not None:
                    raise RuntimeError(f"Model fixture exited before readiness: {fixture.returncode}")
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=0.2) as response:
                        if response.read() == b"fixture ready":
                            break
                except (OSError, TimeoutError):
                    time.sleep(0.1)
            else:
                raise RuntimeError("Model fixture did not become ready within 10 seconds")
            environment = dict(os.environ, EISCUE_TEST_MODEL_PORT=str(port),
                               TEST_RUNNER_EISCUE_TEST_MODEL_PORT=str(port))
            result = subprocess.run(command, env=environment).returncode
            if fixture.poll() is not None:
                print(f"Model fixture exited unexpectedly during the check: {fixture.returncode}", file=sys.stderr)
                if result == 0:
                    result = 2
        finally:
            unexpected_exit = fixture.poll()
            if unexpected_exit is not None and result == 0:
                result = 2
            if unexpected_exit is None:
                fixture.terminate()
                try:
                    fixture.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    fixture.kill()
                    fixture.wait()
            print(f"fixture_exit={fixture.returncode}; intentional_shutdown={unexpected_exit is None}", file=log, flush=True)
        return result if result >= 0 else 128 - result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    command = options.command[1:] if options.command[:1] == ["--"] else options.command
    try:
        return run(options.log, command, options.port)
    except (OSError, RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
