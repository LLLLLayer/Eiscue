#!/usr/bin/env python3
"""Package and safely provision USB S3 or wireless C3 relay firmware.

No phone operations. `inspect` never opens a port; `flash` requires an explicit
USB serial port and ROM chip validation before reading or writing flash.
"""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Firmware/NCM-Relay"
PROFILES = {
    "ncm": {"project": PROJECT, "chip": "esp32s3", "rom_chip": "ESP32-S3",
            "name": "eiscue-ncm-relay", "flash_bytes": 4 * 1024 * 1024},
    "passport": {"project": ROOT / "Firmware/Passport-Relay", "chip": "esp32c3", "rom_chip": "ESP32-C3",
                 "name": "eiscue-passport-relay", "flash_bytes": 8 * 1024 * 1024},
}
PASSPORT_CONFIG_OFFSET = 0xF000
PASSPORT_CONFIG_SIZE = 0x6000
USB_SERIAL_VENDORS = {0x303A, 0x10C4, 0x1A86, 0x0403}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def walk_usb(nodes):
    """Only USB devices, excluding registry root diagnostics and all properties."""
    if isinstance(nodes, dict):
        nodes = [nodes]
    for node in nodes:
        if not isinstance(node, dict):
            continue
        if "idVendor" in node and "idProduct" in node:
            yield {
                "name": node.get("USB Product Name", node.get("kUSBProductString", "USB device")),
                "vendor_id": f'{node["idVendor"]:04x}',
                "product_id": f'{node["idProduct"]:04x}',
                "manufacturer": node.get("USB Vendor Name", node.get("kUSBVendorString", "")),
                "location": node.get("locationID"),
            }
        yield from walk_usb(node.get("IORegistryEntryChildren", []))


def serial_ports():
    try:
        from serial.tools import list_ports
    except ImportError as error:
        raise RuntimeError("Run with the ESP-IDF Python environment (pyserial is required).") from error
    return list(list_ports.comports())


def inspect_usb():
    devices = []
    if sys.platform == "darwin":
        result = subprocess.run(["ioreg", "-p", "IOUSB", "-a", "-l"], check=True, capture_output=True)
        devices = list(walk_usb(plistlib.loads(result.stdout)))
    ports = serial_ports()
    candidates = [{"port": p.device, "description": p.description,
                   "vendor_id": f"{p.vid:04x}", "product_id": f"{p.pid:04x}"}
                  for p in ports if p.vid in USB_SERIAL_VENDORS and p.pid is not None]
    return {"usb_devices": devices, "serial_candidates": candidates,
            "chip_verified": False,
            "note": "USB names/VID do not prove chip or board model. Flash requires ROM verification."}


def private_directory(path: Path):
    path.mkdir(parents=True, exist_ok=False, mode=0o700)
    path.chmod(0o700)


def private_file(path: Path, data: bytes):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def check_package(package: Path):
    manifest = json.loads((package / "manifest.json").read_text())
    profile = PROFILES.get(manifest.get("profile", "ncm"))
    if profile is None or manifest.get("chip") != profile["chip"] or manifest.get("format") != 1:
        raise RuntimeError("Unsupported firmware profile/chip. USB S3 and wireless C3 packages are distinct.")
    if manifest.get("minimum_flash_bytes") != profile["flash_bytes"]:
        raise RuntimeError("Unexpected firmware flash capacity.")
    if manifest.get("version") != (profile["project"] / "VERSION").read_text().strip():
        raise RuntimeError("Package version differs from this checkout. Rebuild firmware first.")
    if not manifest.get("images"):
        raise RuntimeError("Firmware package has no images.")
    last_end = 0
    for image in sorted(manifest["images"], key=lambda image: image["offset"]):
        name, offset = image["file"], image["offset"]
        if not isinstance(name, str) or Path(name).name != name:
            raise RuntimeError("Unsafe firmware filename.")
        path = package / name
        if offset < last_end or offset < 0 or offset % 4096:
            raise RuntimeError("Invalid/overlapping flash regions.")
        if path.stat().st_size != image["size"] or sha256(path) != image["sha256"]:
            raise RuntimeError(f"Firmware integrity check failed: {name}")
        if manifest.get("profile") == "passport" and offset < PASSPORT_CONFIG_OFFSET + PASSPORT_CONFIG_SIZE and offset + image["size"] > PASSPORT_CONFIG_OFFSET:
            raise RuntimeError("Firmware image overlaps the private per-board Wi-Fi configuration.")
        last_end = offset + image["size"]
    if last_end > manifest["minimum_flash_bytes"]:
        raise RuntimeError("Firmware exceeds its declared flash size.")
    return manifest


def package_firmware(build_dir: Path, target="ncm"):
    profile = PROFILES[target]
    args = json.loads((build_dir / "flasher_args.json").read_text())
    if args["extra_esptool_args"]["chip"] != profile["chip"]:
        raise RuntimeError("Build chip does not match the requested firmware profile.")
    version = (profile["project"] / "VERSION").read_text().strip()
    output = build_dir / "release" / f'{profile["name"]}-{version}'
    output.mkdir(parents=True, exist_ok=True)
    images = []
    for raw_offset, raw_file in args["flash_files"].items():
        source = (build_dir / raw_file).resolve()
        if not source.is_relative_to(build_dir.resolve()):
            raise RuntimeError("Build image escaped the build directory.")
        target_path = output / source.name
        shutil.copyfile(source, target_path)
        images.append({"file": target_path.name, "offset": int(raw_offset, 0),
                       "size": target_path.stat().st_size, "sha256": sha256(target_path)})
    flash = args["flash_settings"]
    manifest = {"format": 1, "profile": target, "version": version, "chip": profile["chip"],
                "esp_idf": "5.5.3", "minimum_flash_bytes": profile["flash_bytes"],
                "flash_mode": flash["flash_mode"], "flash_freq": flash["flash_freq"],
                "flash_size": flash["flash_size"], "images": images,
                "upstream_commit": "032864e2339da19ee13025c471f4cf1dfdf4c5cd",
                "protocols": ["ND1", "NR1", "NL1"],
                "hardware_validation": "not-proven-by-build"}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    check_package(output)
    print(output)


def selected_port(port: str):
    ports = [p for p in serial_ports() if p.device == port]
    if len(ports) != 1 or ports[0].vid not in USB_SERIAL_VENDORS:
        raise RuntimeError("Select an enumerated USB serial port from `inspect`; Bluetooth/debug consoles are rejected.")
    return ports[0]


def probe_rom(port: str, minimum_flash=0, backup_dir: Path | None = None, target="ncm"):
    try:
        import esptool
    except ImportError as error:
        raise RuntimeError("Run with the ESP-IDF Python environment (esptool is required).") from error
    selected_port(port)
    # esptool prints identifiers by default. Suppress them rather than exporting
    # raw board metadata, keys, or original flash contents to the console.
    capture = io.StringIO()
    chip = None
    try:
        with redirect_stdout(capture):
            chip = esptool.detect_chip(port, baud=115200)
            name = chip.CHIP_NAME
            if name != PROFILES[target]["rom_chip"]:
                raise RuntimeError(f'Detected {name}; selected {target} requires {PROFILES[target]["rom_chip"]}. No flash was written.')
            if chip.get_secure_boot_enabled() or chip.get_flash_encryption_enabled():
                raise RuntimeError("Secure Boot/Flash Encryption is enabled. No readable, restorable backup can be guaranteed.")
            chip = chip.run_stub()
            # Read the full flash at the same conservative rate used to write
            # it. A factory backup at the ROM's 115200 baud takes many minutes.
            chip.change_baud(460800)
            flash_id = chip.flash_id()
            exponent = (flash_id >> 16) & 0xFF
            if not 20 <= exponent <= 26:
                raise RuntimeError("Unrecognized flash capacity; refusing to guess backup length.")
            size = 1 << exponent
            if size < minimum_flash:
                raise RuntimeError("Board has too little flash for this firmware.")
            identity = {"chip": name, "flash_bytes": size}
            if backup_dir is not None:
                data = chip.read_flash(0, size)
                if len(data) != size:
                    raise RuntimeError("Incomplete backup; flash was not written.")
                expected_md5 = hashlib.md5(data).hexdigest()
                if chip.flash_md5sum(0, size).lower() != expected_md5:
                    raise RuntimeError("Backup readback verification failed; flash was not written.")
                private_directory(backup_dir)
                private_file(backup_dir / "original-flash.bin", data)
                identity["backup_sha256"] = hashlib.sha256(data).hexdigest()
                private_file(backup_dir / "backup.json", (json.dumps(identity, indent=2) + "\n").encode())
            return identity
    finally:
        if chip is not None:
            try:
                with redirect_stdout(capture):
                    chip.hard_reset()
            finally:
                chip._port.close()


def flash_package(port: str, package: Path):
    manifest = check_package(package)
    target = manifest.get("profile", "ncm")
    before = selected_port(port)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    backups = ROOT / ".build/board-backups"
    backups.mkdir(parents=True, exist_ok=True, mode=0o700)
    backups.chmod(0o700)
    backup = backups / timestamp
    identity = probe_rom(port, manifest["minimum_flash_bytes"], backup, target=target)
    configuration = provision_passport(backup) if target == "passport" else None
    after = selected_port(port)
    if (before.vid, before.pid, before.serial_number, before.location) != \
       (after.vid, after.pid, after.serial_number, after.location):
        raise RuntimeError("USB identity changed after backup; refusing to write another board.")
    print(f'Verified {identity["chip"]}, {identity["flash_bytes"]} bytes. Backup: {backup}')
    common = [sys.executable, "-m", "esptool", "--chip", manifest["chip"], "--port", port, "--baud", "460800"]
    settings = ["--flash_mode", manifest["flash_mode"], "--flash_freq", manifest["flash_freq"],
                "--flash_size", manifest["flash_size"]]
    images = []
    for image in manifest["images"]:
        images += [hex(image["offset"]), str(package / image["file"])]
    if configuration is not None:
        images += [hex(PASSPORT_CONFIG_OFFSET), str(configuration)]
    for action in ["write_flash", "verify_flash"]:
        result = subprocess.run(common + [action] + settings + images, capture_output=True)
        if result.returncode:
            raise RuntimeError(f"esptool {action} failed. The verified original backup remains at {backup}.")
        print(f"{action} passed.")
    print("Flash and readback verification passed. This does not prove network or iPhone control.")
    if configuration is not None:
        print(f'Private Wi-Fi setup: {backup / "wifi-setup.txt"}')


def provision_passport(directory: Path) -> Path:
    """Generate fresh per-board credentials only inside the verified backup folder.

    The firmware uses a dedicated NVS partition; no credentials are compiled
    into a distributable image. Never log the password or original flash data.
    """
    idf_path = os.environ.get("IDF_PATH")
    if not idf_path:
        raise RuntimeError("Set IDF_PATH to provision the Passport NVS image. No firmware was written.")
    generator = Path(idf_path) / "components/nvs_flash/nvs_partition_generator/nvs_partition_gen.py"
    if not generator.is_file():
        raise RuntimeError("ESP-IDF NVS generator was not found. No firmware was written.")
    ssid = "Eiscue-" + secrets.token_hex(3).upper()
    password = secrets.token_urlsafe(18)
    csv_path = directory / "wifi-config.csv"
    binary_path = directory / "wifi-config.bin"
    csv_data = f"key,type,encoding,value\nrelay,namespace,,\nssid,data,string,{ssid}\npassword,data,string,{password}\n"
    private_file(csv_path, csv_data.encode())
    # Pre-create the output privately; generator truncates it without widening
    # permissions. The parent directory is also 0700.
    private_file(binary_path, b"")
    result = subprocess.run([sys.executable, str(generator), "generate", str(csv_path),
                             str(binary_path), hex(PASSPORT_CONFIG_SIZE)], capture_output=True)
    if result.returncode or binary_path.stat().st_size != PASSPORT_CONFIG_SIZE:
        raise RuntimeError("Wi-Fi configuration image generation failed. No firmware was written.")
    binary_path.chmod(0o600)
    setup = ("Eiscue Passport wireless relay\n\n"
             f"Wi-Fi: {ssid}\nPassword: {password}\n\n"
             "Connect the iPhone to this Wi-Fi, then select Wireless board in Eiscue.\n"
             "The board supplies a local connection, not internet access.\n"
             "Keep cellular data enabled if needed. VPN local-network access depends on its policy.\n"
             "These credentials are private. Do not commit or publish this file.\n")
    private_file(directory / "wifi-setup.txt", setup.encode())
    # QR payload is deliberately stored only in the protected local folder.
    private_file(directory / "wifi-qr.txt", f"WIFI:T:WPA;S:{ssid};P:{password};;".encode())
    return binary_path


def check_link(interface: str, target="ncm"):
    if sys.platform != "darwin":
        raise RuntimeError("This link check currently supports macOS interface binding only.")
    index = socket.if_nametoindex(interface)
    config = subprocess.run(["ifconfig", interface], capture_output=True, text=True, check=True).stdout
    hardware = subprocess.run(["networksetup", "-listallhardwareports"],
                              capture_output=True, text=True, check=True).stdout
    ports = [block for block in hardware.split("\n\n")
             if re.search(rf"^Device: {re.escape(interface)}$", block, re.MULTILINE)]
    expected_port = r"^Hardware Port: Wi-Fi$" if target == "passport" else r"^Hardware Port: .*\b(?:USB|Eiscue NCM Relay)\b"
    if len(ports) != 1 or not re.search(expected_port, ports[0], re.MULTILINE):
        raise RuntimeError("Selected interface does not match the explicit USB/Wi-Fi transport; VPN interfaces are rejected.")
    flags = re.search(r"flags=[0-9a-f]+<([^>]+)>", config)
    flag_set = set(flags.group(1).split(",")) if flags else set()
    if not {"UP", "RUNNING", "BROADCAST"}.issubset(flag_set) or {"LOOPBACK", "POINTOPOINT"} & flag_set:
        raise RuntimeError("Selected interface is not an active Ethernet link.")
    mask = "fffffffc" if target == "passport" else "ffffff00"
    if not re.search(rf"\binet 192\.168\.7\.2 netmask 0x{mask}\b", config) or "ether " not in config:
        raise RuntimeError("Selected interface must have the firmware's exact .2 address and subnet mask.")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as stream:
        stream.settimeout(4)
        # IP_BOUND_IF is 25 in Darwin netinet/in.h. Bind both interface and IP,
        # so diagnostics cannot quietly take the Wi-Fi/VPN route.
        stream.setsockopt(socket.IPPROTO_IP, 25, index)
        stream.bind(("192.168.7.2", 0))
        stream.connect(("192.168.7.1", 28767))
        stream.sendall(b"STATUS\n")
        result = bytearray()
        deadline = time.monotonic() + 4
        while len(result) <= 4096:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("ND1 reply exceeded its absolute timeout.")
            stream.settimeout(remaining)
            data = stream.recv(min(4097 - len(result), 4096))
            if not data:
                break
            result.extend(data)
        if len(result) > 4096 or not result.endswith(b"\n") or b"\n" in result[:-1]:
            raise RuntimeError("Malformed/oversized ND1 reply.")
        reply = json.loads(result)
        if (reply.get("protocol"), reply.get("layer"), reply.get("result"), reply.get("authenticated")) != \
           ("ND1", "ncm", "diagnostic-only", False):
            raise RuntimeError("Peer did not return the expected diagnostic-only ND1 status.")
    print(json.dumps({"interface": interface, "round_trip": "passed", "protocol": "ND1",
                      "device_control": "not-verified", "vpn_coexistence": "not-verified"}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("inspect", help="Read-only USB and serial inventory; no port opens.")
    probe = commands.add_parser("probe", help="Read ROM chip/capacity; may reset the explicitly selected board.")
    probe.add_argument("--port", required=True)
    probe.add_argument("--target", choices=PROFILES, default="ncm")
    link = commands.add_parser("check-link", help="Read-only, interface-bound ND1 STATUS round trip on Mac.")
    link.add_argument("--interface", required=True)
    link.add_argument("--target", choices=PROFILES, default="ncm")
    package = commands.add_parser("package", help="Package an existing relay build with SHA-256 manifest.")
    package.add_argument("--build-dir", required=True, type=Path)
    package.add_argument("--target", choices=PROFILES, default="ncm")
    verify = commands.add_parser("verify-package")
    verify.add_argument("--package", required=True, type=Path)
    flash = commands.add_parser("flash", help="Validate ROM, back up ALL flash privately, then write/verify firmware.")
    flash.add_argument("--port", required=True)
    flash.add_argument("--package", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            print(json.dumps(inspect_usb(), ensure_ascii=False, indent=2))
        elif args.command == "probe":
            print(json.dumps(probe_rom(args.port, target=args.target), indent=2))
        elif args.command == "package":
            package_firmware(args.build_dir.resolve(), args.target)
        elif args.command == "check-link":
            check_link(args.interface, args.target)
        elif args.command == "verify-package":
            check_package(args.package.resolve())
            print("Package integrity passed.")
        elif args.command == "flash":
            flash_package(args.port, args.package.resolve())
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(2, f"{error}\n")


if __name__ == "__main__":
    main()
