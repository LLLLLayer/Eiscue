#!/usr/bin/env python3
"""Explicitly pair one USB iOS device and send its identity to Eiscue on macOS."""

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parent.parent
APP_ID = "org.eiscue.app"
TRANSFER_NAME = "EiscuePairingTransfer.json"
RUST_TOOLCHAIN = "1.96.0"


class SetupError(Exception):
    pass


class SetupCancelled(Exception):
    pass


@dataclass(frozen=True)
class USBDevice:
    name: str
    udid: str
    identifier: str
    developer_mode: str
    paired: bool
    ddi_ready: bool


def stop_process_group(process):
    # The build shell can have Cargo/rustc children; stop the entire owned group
    # before removing the directory in which pairing may still be writing.
    previous = {number: signal.signal(number, signal.SIG_IGN)
                for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        # A finished leader does not mean its descendants closed the pipes or
        # stopped writing. Kill any remaining members even after leader exit.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    finally:
        for number, previous_handler in previous.items():
            signal.signal(number, previous_handler)


def run_command(arguments, *, failure, timeout=60):
    environment = dict(os.environ, EISCUE_RUST_TOOLCHAIN=RUST_TOOLCHAIN)
    try:
        process = subprocess.Popen(
            arguments, cwd=ROOT, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            encoding="utf-8", errors="replace",
            start_new_session=True,
        )
    except OSError:
        raise SetupError(failure) from None
    try:
        output, _ = process.communicate(timeout=timeout)
    except BaseException:
        stop_process_group(process)
        raise
    finally:
        process.stdout.close()
        process.stderr.close()
    if process.returncode != 0:
        # Child diagnostics are deliberately not forwarded: device responses
        # and compiler environments are not a safe source of credential logs.
        raise SetupError(failure)
    return output


def preflight(run=run_command):
    if platform.system() != "Darwin":
        raise SetupError("This setup command requires macOS with Xcode. It does not support Linux.")
    if sys.version_info < (3, 9):
        raise SetupError("Python 3.9 or newer is required.")
    if not (ROOT / "Scripts/pair-device-usb.sh").is_file():
        raise SetupError("Run this command from a complete Eiscue source checkout.")
    if not shutil.which("xcrun") or not shutil.which("xcodebuild"):
        raise SetupError("Install Xcode 26 or newer and open it to finish setup, then retry.")
    version = run(["xcodebuild", "-version"], failure="Open Xcode and finish its setup, then retry.")
    match = re.search(r"^Xcode (\d+)", version, re.MULTILINE)
    if not match or int(match.group(1)) < 26:
        raise SetupError("Select Xcode 26 or newer as the active developer directory, then retry.")
    run(["xcrun", "--find", "devicectl"], failure="The selected Xcode does not provide devicectl.")
    if not shutil.which("rustup"):
        raise SetupError("Install Rust with rustup and its 1.96.0 toolchain, then retry.")
    rust = run(["rustup", "run", RUST_TOOLCHAIN, "rustc", "--version"],
               failure="Rust 1.96.0 is required. Install that toolchain with rustup, then retry.")
    if not rust.startswith("rustc 1.96.0 "):
        raise SetupError("The Rust 1.96.0 toolchain could not be verified.")


def read_result(path):
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if payload["info"]["outcome"] != "success" or not isinstance(payload["result"], dict):
            raise ValueError()
        return payload["result"]
    except (OSError, ValueError, KeyError, TypeError):
        raise SetupError("Xcode returned an unexpected result. No automatic fallback was used; retry after checking Xcode.") from None


def usb_devices(result):
    records = result.get("devices")
    if not isinstance(records, list):
        raise SetupError("Xcode did not return a device list.")
    devices = []
    seen = set()
    for record in records:
        if not isinstance(record, dict):
            continue
        hardware = record.get("hardwareProperties", {})
        connection = record.get("connectionProperties", {})
        properties = record.get("deviceProperties", {})
        if not all(isinstance(value, dict) for value in (hardware, connection, properties)):
            continue
        if (hardware.get("reality") != "physical"
                or hardware.get("deviceType") not in ("iPhone", "iPad")
                or hardware.get("platform") != "iOS"
                or connection.get("transportType") != "wired"):
            continue
        udid = hardware.get("udid", "")
        identifier = record.get("identifier", "")
        name = properties.get("name", "")
        if not isinstance(udid, str) or not re.fullmatch(r"[0-9A-Fa-f-]{8,80}", udid):
            continue
        if not isinstance(name, str) or not name.strip():
            continue
        try:
            uuid.UUID(identifier)
        except (ValueError, AttributeError, TypeError):
            continue
        if udid in seen:
            raise SetupError("Xcode returned duplicate USB device identifiers. Disconnect and reconnect the intended device, then retry.")
        seen.add(udid)
        # A device name can contain terminal control characters; display text
        # must not alter the terminal prompt or hide the selected identifier.
        name = "".join(character for character in name if character.isprintable())[:100]
        devices.append(USBDevice(name, udid, identifier, properties.get("developerModeStatus", "unknown"),
                                 connection.get("pairingState") == "paired",
                                 properties.get("ddiServicesAvailable") is True))
    return sorted(devices, key=lambda device: (device.name.casefold(), device.udid))


def list_usb_devices(directory, run):
    output = directory / "devices.json"
    run(["xcrun", "devicectl", "list", "devices", "--timeout", "30", "--json-output", str(output)],
        failure="Could not list devices. Keep the iPhone/iPad unlocked and connected with a USB data cable.")
    return usb_devices(read_result(output))


def choose_device(devices, ask=input, write=print):
    if not devices:
        raise SetupError("No USB iPhone/iPad is available. Connect a USB data cable, unlock it, trust this computer in Finder/Xcode, then retry. Wi-Fi devices are not selected.")
    write("USB devices:")
    for index, device in enumerate(devices, start=1):
        write(f"  {index}. {device.name} ({device.udid})")
    while True:
        answer = ask("Select the device number, or q to cancel: ").strip()
        if answer.casefold() == "q":
            raise SetupCancelled()
        if answer.isascii() and answer.isdecimal() and 1 <= int(answer) <= len(devices):
            return devices[int(answer) - 1]
        write("Enter one of the displayed numbers. There is no default device.")


def check_preparation(device):
    if not device.paired:
        raise SetupError("Unlock the selected device and trust this computer in Finder/Xcode, then retry.")
    if device.developer_mode != "enabled":
        raise SetupError("Xcode has not confirmed Developer Mode. Enable it in Settings > Privacy & Security on the device, then reconnect in Xcode and retry.")
    if not device.ddi_ready:
        raise SetupError("Xcode has not confirmed the developer environment (DDI). Select this device in Xcode > Window > Devices and Simulators and finish device preparation, then retry. This script does not prepare DDI.")


def check_transfer_destination(device, directory, run):
    output = directory / "app-files.json"
    run(["xcrun", "devicectl", "device", "info", "files", "--device", device.udid,
         "--domain-type", "appDataContainer", "--domain-identifier", APP_ID,
         "--subdirectory", "tmp", "--no-recurse", "--timeout", "30", "--json-output", str(output)],
        failure="Could not access Eiscue on the selected device. Install and open Eiscue first; keep the device unlocked and check Xcode's device preparation, then retry.")
    result = read_result(output)
    if (result.get("deviceIdentifier") != device.identifier or result.get("domain") != "appDataContainer"
            or result.get("domainIdentifier") != APP_ID or not isinstance(result.get("files"), list)):
        raise SetupError("Xcode did not confirm the selected Eiscue container. Nothing was sent.")
    for file in result["files"]:
        if not isinstance(file, dict) or not isinstance(file.get("name"), str):
            raise SetupError("Xcode returned an unexpected file listing. Nothing was sent.")
        if file["name"] == TRANSFER_NAME:
            raise SetupError("Eiscue already has a pairing file waiting for import. Import that file on the device first, or resolve it in the app, then retry. It was not replaced.")


def validate_private_file(path):
    try:
        metadata = path.lstat()
    except OSError:
        raise SetupError("The pairing tool did not produce an identity. Nothing was sent.") from None
    if (not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_uid != os.getuid() or not 0 < metadata.st_size <= 32 * 1024):
        raise SetupError("The pairing output failed its private-file check. Nothing was sent.")


def setup(run=run_command, ask=input, write=print):
    preflight(run)
    write("Keep your iPhone/iPad unlocked and connected by USB. Developer Mode, computer trust and Xcode device preparation (DDI) are required.")
    write("This command creates an Eiscue pairing identity and enables Wi-Fi developer connections. It does not prepare DDI, launch Eiscue, import the identity, or connect a VPN.")
    with tempfile.TemporaryDirectory(prefix="eiscue-pairing-") as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        device = choose_device(list_usb_devices(directory, run), ask, write)
        check_preparation(device)
        check_transfer_destination(device, directory, run)
        if ask(f"Pair and send to {device.name} ({device.udid})? [y/N]: ").strip().casefold() not in ("y", "yes"):
            raise SetupCancelled()
        identity = directory / TRANSFER_NAME
        write("Building the pairing tool and preparing the identity. The first build may take several minutes and download locked project dependencies.")
        run(["/bin/bash", str(ROOT / "Scripts/pair-device-usb.sh"), "--udid", device.udid,
             "--output", str(identity), "--enable-wifi"], timeout=900,
            failure="USB pairing failed. Check the selected device's trust and Developer Mode, and the Mac's network access for the first build, then retry. Nothing was sent.")
        validate_private_file(identity)
        # The user may have disconnected the cable while Cargo was building.
        if device.udid not in {candidate.udid for candidate in list_usb_devices(directory, run)}:
            raise SetupError("The selected device is no longer connected over USB. Nothing was sent; reconnect it and retry.")
        check_transfer_destination(device, directory, run)
        write("Sending the identity to Eiscue on the selected device...")
        result_file = directory / "transfer-result.json"
        run(["xcrun", "devicectl", "device", "copy", "to", "--device", device.udid,
             "--source", str(identity), "--destination", f"tmp/{TRANSFER_NAME}",
             "--domain-type", "appDataContainer", "--domain-identifier", APP_ID,
             "--timeout", "60", "--json-output", str(result_file)], timeout=75,
            failure="Transfer was not confirmed. Check Eiscue for a pending pairing import before retrying; no identity was automatically imported.")
        read_result(result_file)
    write("Sent. The Mac's temporary pairing file has been removed.")
    write("On the iPhone/iPad, return to Eiscue > Device > In-app connection and choose Import from computer. Confirm the import there, then connect the device.")


def main(arguments=None):
    parser = argparse.ArgumentParser(
        description="Select a USB iPhone/iPad, generate a private Eiscue pairing identity, and send it to the installed app for manual import.",
        epilog="Run from the Eiscue source checkout: python3 Scripts/setup-device.py. Requires macOS, Xcode 26+, Python 3.9+, Rust 1.96.0, Developer Mode, USB trust and prepared DDI. No global tools are installed; the first Cargo build can download locked project dependencies. --help does not inspect or modify devices.",
    )
    parser.parse_args(arguments)
    previous_term = signal.getsignal(signal.SIGTERM)
    def interrupt(_signal, _frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupt)
    try:
        setup()
        return 0
    except (KeyboardInterrupt, EOFError, SetupCancelled):
        print("Cancelled. Mac temporary pairing files were removed. If sending had started, check Eiscue for a pending import before retrying.", file=sys.stderr)
        return 130
    except (SetupError, subprocess.TimeoutExpired) as error:
        message = str(error) if isinstance(error, SetupError) else "The command timed out. Check the selected device and retry."
        print(f"Setup stopped: {message}\nMac temporary pairing files were removed.", file=sys.stderr)
        return 1
    except OSError:
        print("Setup stopped: a local file could not be accessed or cleaned up. Check your Mac's temporary-folder permissions before retrying.", file=sys.stderr)
        return 1
    finally:
        signal.signal(signal.SIGTERM, previous_term)


if __name__ == "__main__":
    sys.exit(main())
