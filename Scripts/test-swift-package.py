#!/usr/bin/env python3
"""Run Kit tests without allowing SwiftPM to rewrite the shared Xcode lockfile.

Usage: DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
    python3 Scripts/test-swift-package.py --scratch-path .build/kit-xcode26 [swift test options]

The manifest and lockfile are copied to a disposable package directory. Source
and vendor directories are symlinked, so diagnostics still refer to real sources.
Neither the original Package.resolved nor Git's index is ever restored or written.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def lock_state(root):
    path = root / "Package.resolved"
    content = path.read_bytes() if path.exists() else None
    index = subprocess.check_output(
        ["git", "ls-files", "--stage", "--", "Package.resolved"], cwd=root
    )
    return content, index


def run(root, scratch_path, arguments):
    if any(arg.split("=", 1)[0] in ("--package-path", "--scratch-path") for arg in arguments):
        raise ValueError("Pass --scratch-path to this wrapper; --package-path cannot override isolation")
    root = root.resolve()
    scratch_path = scratch_path.resolve()
    if scratch_path in (root, root / ".build"):
        raise ValueError("Use a dedicated scratch directory for this toolchain, not the package root or .build")
    if not os.environ.get("DEVELOPER_DIR"):
        raise ValueError("Set DEVELOPER_DIR explicitly for this check")
    before = lock_state(root)
    build = root / ".build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="swiftpm-input-", dir=build) as temporary:
        package = Path(temporary)
        for manifest in root.glob("Package*.swift"):
            (package / manifest.name).write_bytes(manifest.read_bytes())
        if before[0] is not None:
            (package / "Package.resolved").write_bytes(before[0])
        for name in ("Sources", "Tests", "Vendor"):
            (package / name).symlink_to(root / name, target_is_directory=True)
        if lock_state(root) != before:
            print("Package.resolved changed while preparing the check; no shared files were written", file=sys.stderr)
            return 2
        print(f"Isolated SwiftPM package: {package}; scratch: {scratch_path}", flush=True)
        command = ["xcrun", "swift", "test", "--package-path", str(package),
                   "--scratch-path", str(scratch_path), *arguments]
        try:
            result = subprocess.run(command, cwd=root).returncode
        finally:
            changed = lock_state(root) != before
        if changed:
            print("Package.resolved worktree or staged contents changed concurrently; "
                  "rejecting this check without overwriting those edits", file=sys.stderr)
            return 2
        return result if result >= 0 else 128 - result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", required=True, type=Path)
    options, arguments = parser.parse_known_args()
    try:
        return run(Path(__file__).resolve().parent.parent, options.scratch_path, arguments)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
