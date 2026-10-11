"""Flash guard tests use fake ROM/serial objects, never a USB device."""
import importlib.util
import hashlib
import json
from pathlib import Path
import sys
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

    @patch.object(board, "selected_port")
    def test_c3_rejected_before_stub_or_flash_read(self, port):
        chip = FakeChip()
        chip.CHIP_NAME = "ESP32-C3"
        with self.rom(chip), self.assertRaisesRegex(RuntimeError, "cannot expose USB NCM"):
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
            with self.assertRaisesRegex(RuntimeError, "cannot expose USB NCM"):
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

    def test_ioreg_inventory_filters_identifiers_and_diagnostics(self):
        rows = list(board.walk_usb([{"IOKitDiagnostics": {"secret": "unused"},
                    "IORegistryEntryChildren": [{"idVendor": 0x303A, "idProduct": 0x1001,
                                                 "USB Serial Number": "private"}]}]))
        self.assertEqual(rows[0]["vendor_id"], "303a")
        self.assertNotIn("USB Serial Number", rows[0])
        self.assertNotIn("IOKitDiagnostics", rows[0])


if __name__ == "__main__":
    unittest.main()
