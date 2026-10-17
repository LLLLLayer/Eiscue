#!/usr/bin/env python3
"""Offline tests for the lockfile-isolated SwiftPM runner; never invoke Swift."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "test-swift-package.py"
spec = importlib.util.spec_from_file_location("swift_package", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SwiftPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "--quiet")
        (self.root / "Package.swift").write_text("// offline manifest fixture\n")
        for name in ("Sources", "Tests", "Vendor"):
            (self.root / name).mkdir()
        self.lock = self.root / "Package.resolved"
        self.lock.write_bytes(b"staged lockfile\n")
        self.git("add", "Package.resolved")
        self.lock.write_bytes(b"unstaged lockfile with Xcode-only pins\n")
        self.original = runner.lock_state(self.root)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "xcrun"
        fake.write_text("""#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
assert args[:2] == ['swift', 'test']
package = pathlib.Path(args[args.index('--package-path') + 1])
root = pathlib.Path.cwd()
assert package != root
assert (package / 'Sources').resolve() == root / 'Sources'
assert (package / 'Vendor').resolve() == root / 'Vendor'
assert (package / 'Package.swift').read_bytes() == (root / 'Package.swift').read_bytes()
assert (package / 'Package.resolved').read_bytes() == (root / 'Package.resolved').read_bytes()
(package / 'Package.resolved').write_text('SwiftPM subset of pins')
(root / 'invocation.json').write_text(json.dumps(args))
mode = os.environ.get('FIXTURE_MODE')
if mode == 'edit':
    (root / 'Package.resolved').write_text('concurrent user worktree edit')
if mode == 'stage':
    (root / 'Package.resolved').write_text('concurrent staged edit')
    subprocess.run(['git', 'add', 'Package.resolved'], check=True)
    (root / 'Package.resolved').write_text('unstaged lockfile with Xcode-only pins\\n')
sys.exit(int(os.environ.get('FIXTURE_EXIT', '0')))
""")
        fake.chmod(0o755)
        self.environment = patch.dict(os.environ, {"PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                                                 "DEVELOPER_DIR": "/fixture/Xcode.app/Contents/Developer"})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.root)

    def run_check(self, arguments=()):
        return runner.run(self.root, self.root / ".build/kit-fixture", list(arguments))

    def test_preserves_distinct_staged_and_unstaged_contents(self):
        self.assertEqual(self.run_check(["--filter", "FixtureTests"]), 0)
        self.assertEqual(runner.lock_state(self.root), self.original)
        invocation = json.loads((self.root / "invocation.json").read_text())
        self.assertEqual(invocation[-2:], ["--filter", "FixtureTests"])
        self.assertFalse(list((self.root / ".build").glob("swiftpm-input-*")))

    def test_propagates_child_failure_and_preserves_lock(self):
        with patch.dict(os.environ, {"FIXTURE_EXIT": "65"}):
            self.assertEqual(self.run_check(), 65)
        self.assertEqual(runner.lock_state(self.root), self.original)

    def test_rejects_concurrent_worktree_change_without_restoring_it(self):
        with patch.dict(os.environ, {"FIXTURE_MODE": "edit"}):
            self.assertEqual(self.run_check(), 2)
        self.assertEqual(self.lock.read_text(), "concurrent user worktree edit")
        self.assertEqual(runner.lock_state(self.root)[1], self.original[1])

    def test_rejects_concurrent_index_change_even_if_worktree_is_unchanged(self):
        with patch.dict(os.environ, {"FIXTURE_MODE": "stage"}):
            self.assertEqual(self.run_check(), 2)
        self.assertEqual(self.lock.read_bytes(), self.original[0])
        self.assertNotEqual(runner.lock_state(self.root)[1], self.original[1])

    def test_cannot_bypass_isolated_package_or_scratch(self):
        for option in ["--package-path=/elsewhere", "--package-path", "--scratch-path=/shared"]:
            with self.assertRaises(ValueError):
                self.run_check([option])
        self.assertFalse((self.root / "invocation.json").exists())

    def test_requires_explicit_toolchain(self):
        with patch.dict(os.environ, {"DEVELOPER_DIR": ""}):
            with self.assertRaises(ValueError):
                self.run_check()


if __name__ == "__main__":
    unittest.main()
