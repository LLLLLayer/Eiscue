"""Flash guard tests use fake ROM/serial objects, never a USB device."""
import importlib.util
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import sys
import struct
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("board_tools", ROOT / "Scripts/board-firmware.py")
board = importlib.util.module_from_spec(spec)
spec.loader.exec_module(board)


class FakeChip:
    CHIP_NAME = "ESP32-S3"

    def __init__(self):
        self._port = types.SimpleNamespace(close=lambda: None)
        self.stub_started = False
        self.read_count = 0
        self.data = b"x" * (1 << 20)

    def get_secure_boot_enabled(self):
        return False

    def get_flash_encryption_enabled(self):
        return False

    def run_stub(self):
        self.stub_started = True
        return self

    def change_baud(self, baud):
        assert baud == 460800

    def flash_id(self):
        return (20 << 16) | 0x4010

    def read_flash(self, offset, size):
        self.read_count += 1
        return self.data[:size]

    def flash_md5sum(self, offset, size):
        return hashlib.md5(self.data[:size]).hexdigest()

    def hard_reset(self):
        pass


class BoardGuardTests(unittest.TestCase):
    def rom(self, chip):
        return patch.dict(sys.modules, {"esptool": types.SimpleNamespace(detect_chip=lambda *a, **k: chip)})

    @patch.object(board.subprocess, "run")
    @patch.object(board, "serial_ports")
    def test_removed_profile_rejected_by_cli_before_io(self, ports, command):
        for arguments in (["probe", "--port", "/dev/fake"],
                          ["package", "--build-dir", "/nonexistent"],
                          ["check-link", "--interface", "en0"]):
            with self.subTest(command=arguments[0]), patch.object(sys, "argv", ["board-firmware.py", *arguments, "--target", "passport"]):
                error = io.StringIO()
                with redirect_stderr(error), self.assertRaises(SystemExit) as result:
                    board.main()
                self.assertEqual(result.exception.code, 2)
                self.assertIn("invalid choice: 'passport'", error.getvalue())
        ports.assert_not_called()
        command.assert_not_called()

    @patch.object(board, "selected_port")
    def test_removed_package_rejected_before_serial_selection(self, port):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / "manifest.json").write_text(json.dumps({
                "format": 1, "profile": "passport", "chip": "esp32c3",
                "version": "1.0.0", "minimum_flash_bytes": 8 * 1024 * 1024,
            }))
            with self.assertRaisesRegex(RuntimeError, "Unsupported firmware profile/chip"):
                board.flash_package("/dev/fake", path)
            self.assertEqual({file.name for file in path.iterdir()}, {"manifest.json"})
        port.assert_not_called()

    def test_supported_profiles_package_and_verify(self):
        for target in ("ncm", "s3-hid"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp)
                hid = target == "s3-hid"
                app_name = "eiscue_passport_ble.bin" if hid else "eiscue_ncm_relay.bin"
                files = {"0x0": "bootloader.bin", "0x8000": "partition-table.bin",
                         "0x20000" if hid else "0x10000": app_name}
                for name in files.values():
                    (path / name).write_bytes(b"synthetic firmware fixture")
                (path / "flasher_args.json").write_text(json.dumps({
                    "extra_esptool_args": {"chip": "esp32s3"}, "flash_files": files,
                    "flash_settings": {"flash_mode": "dio", "flash_freq": "80m",
                                       "flash_size": "16MB" if hid else "4MB"},
                }))
                output = io.StringIO()
                with redirect_stdout(output):
                    board.package_firmware(path, target)
                manifest = board.check_package(Path(output.getvalue().strip()))
                self.assertEqual(manifest["profile"], target)
                self.assertEqual({image["file"] for image in manifest["images"]}, set(files.values()))

    @patch.object(board.sys, "platform", "darwin")
    @patch.object(board.socket, "socket")
    @patch.object(board.socket, "if_nametoindex", return_value=5)
    @patch.object(board.subprocess, "run")
    def test_ncm_link_rejects_wifi_and_vpn_before_socket(self, command, index, stream):
        config = "flags=8863<UP,BROADCAST,RUNNING>\n\tether 00:11:22:33:44:55\n\tinet 192.168.7.2 netmask 0xffffff00\n"
        for hardware in ("Wi-Fi", "VPN"):
            with self.subTest(hardware=hardware):
                command.side_effect = [types.SimpleNamespace(stdout=config),
                                       types.SimpleNamespace(stdout=f"Hardware Port: {hardware}\nDevice: en0\n")]
                with self.assertRaisesRegex(RuntimeError, "not a USB NCM link"):
                    board.check_link("en0")
        stream.assert_not_called()

    @patch.object(board.sys, "platform", "darwin")
    @patch.object(board.socket, "socket")
    @patch.object(board.socket, "if_nametoindex", return_value=5)
    @patch.object(board.subprocess, "run")
    def test_ncm_link_rejects_removed_subnet_before_socket(self, command, index, stream):
        command.side_effect = [types.SimpleNamespace(stdout="flags=8863<UP,BROADCAST,RUNNING>\n\tether 00:11:22:33:44:55\n\tinet 192.168.7.2 netmask 0xfffffffc\n"),
                               types.SimpleNamespace(stdout="Hardware Port: Eiscue NCM Relay\nDevice: en0\n")]
        with self.assertRaisesRegex(RuntimeError, "exact .2 address and subnet mask"):
            board.check_link("en0")
        stream.assert_not_called()

    @patch.object(board, "selected_port")
    def test_c3_rejected_before_stub_or_flash_read(self, port):
        chip = FakeChip()
        chip.CHIP_NAME = "ESP32-C3"
        with self.rom(chip), self.assertRaisesRegex(RuntimeError, "selected ncm requires ESP32-S3"):
            board.probe_rom("/dev/fake")
        self.assertFalse(chip.stub_started)
        self.assertEqual(chip.read_count, 0)

    @patch.object(board.subprocess, "run")
    @patch.object(board, "selected_port")
    @patch.object(board, "check_package", return_value={"minimum_flash_bytes": 4 * 1024 * 1024})
    def test_flash_command_c3_never_calls_write_tool(self, package, port, command):
        chip = FakeChip()
        chip.CHIP_NAME = "ESP32-C3"
        with tempfile.TemporaryDirectory() as tmp, patch.object(board, "ROOT", Path(tmp)), self.rom(chip):
            with self.assertRaisesRegex(RuntimeError, "selected ncm requires ESP32-S3"):
                board.flash_package("/dev/fake", Path(tmp))
        command.assert_not_called()

    @patch.object(board, "selected_port")
    def test_encrypted_board_rejected_before_flash_read(self, port):
        chip = FakeChip()
        chip.get_flash_encryption_enabled = lambda: True
        with self.rom(chip), self.assertRaisesRegex(RuntimeError, "Flash Encryption"):
            board.probe_rom("/dev/fake")
        self.assertFalse(chip.stub_started)
        self.assertEqual(chip.read_count, 0)

    @patch.object(board, "selected_port")
    def test_backup_verified_and_private(self, port):
        chip = FakeChip()
        with tempfile.TemporaryDirectory() as tmp, self.rom(chip):
            path = Path(tmp) / "private-backup"
            result = board.probe_rom("/dev/fake", backup_dir=path)
            self.assertEqual((path / "original-flash.bin").read_bytes(), chip.data)
            self.assertEqual(result["backup_sha256"], hashlib.sha256(chip.data).hexdigest())
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
            self.assertEqual((path / "original-flash.bin").stat().st_mode & 0o777, 0o600)
            self.assertEqual((path / "backup.json").stat().st_mode & 0o777, 0o600)

    @patch.object(board, "selected_port")
    def test_backup_mismatch_does_not_save_a_restorable_claim(self, port):
        chip = FakeChip()
        chip.flash_md5sum = lambda *a: "0" * 32
        with tempfile.TemporaryDirectory() as tmp, self.rom(chip):
            path = Path(tmp) / "private-backup"
            with self.assertRaisesRegex(RuntimeError, "verification failed"):
                board.probe_rom("/dev/fake", backup_dir=path)
            self.assertFalse(path.exists())

    def test_package_tampering_rejected_before_hardware_operation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            image = path / "firmware.bin"
            image.write_bytes(b"original")
            manifest = {"format": 1, "chip": "esp32s3", "version": "1.0.0",
                        "minimum_flash_bytes": 4 * 1024 * 1024,
                        "images": [{"file": image.name, "offset": 0x10000,
                                    "size": image.stat().st_size, "sha256": board.sha256(image)}]}
            (path / "manifest.json").write_text(json.dumps(manifest))
            board.check_package(path)
            image.write_bytes(b"tampered")
            with self.assertRaisesRegex(RuntimeError, "integrity check failed"):
                board.check_package(path)

    def test_s3_hid_rejects_truncated_original_nvs_before_writing(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "backup.bin"
            def layout(size):
                row = struct.pack("<HBBII16sI", 0x50AA, 1, 2, 0x9000, size, b"nvs", 0)
                path.write_bytes(b"\xff" * 0x8000 + row + b"\xff" * (0x1000 - len(row)))
            layout(0x6000)
            board.check_s3_nvs_layout(path)
            layout(0x5000)
            with self.assertRaisesRegex(RuntimeError, "Original NVS layout differs"):
                board.check_s3_nvs_layout(path)

    def test_s3_hid_package_cannot_write_private_partitions(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            image = path / "nvs.bin"
            image.write_bytes(b"private")
            manifest = {"format": 1, "profile": "s3-hid", "chip": "esp32s3",
                        "version": (board.PROFILES["s3-hid"]["project"] / "VERSION").read_text().strip(),
                        "minimum_flash_bytes": 16 * 1024 * 1024, "flash_size": "16MB",
                        "images": [{"file": image.name, "offset": 0x9000,
                                    "size": image.stat().st_size, "sha256": board.sha256(image)}]}
            for offset in (0x9000, 0xF000, 0x10000):
                with self.subTest(offset=hex(offset)):
                    manifest["images"][0]["offset"] = offset
                    (path / "manifest.json").write_text(json.dumps(manifest))
                    with self.assertRaisesRegex(RuntimeError, "NVS is preserved"):
                        board.check_package(path)

    def test_ioreg_inventory_filters_identifiers_and_diagnostics(self):
        rows = list(board.walk_usb([{"IOKitDiagnostics": {"secret": "unused"},
                    "IORegistryEntryChildren": [{"idVendor": 0x303A, "idProduct": 0x1001,
                                                 "USB Serial Number": "private"}]}]))
        self.assertEqual(rows[0]["vendor_id"], "303a")
        self.assertNotIn("USB Serial Number", rows[0])
        self.assertNotIn("IOKitDiagnostics", rows[0])


if __name__ == "__main__":
    unittest.main()
