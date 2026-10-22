#!/usr/bin/env python3
"""Record/check which native sources and headers produced the shipped archives.

This is a build freshness check, not a device-control acceptance test.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import sys


ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "Vendor/DeviceBackend"
DEFAULT_FRAMEWORK = BACKEND / "Frameworks/EiscueNativeBackend.xcframework"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    rust = BACKEND / "rust"
    paths = [rust / "Cargo.toml", rust / "Cargo.lock"]
    paths += sorted((rust / "src").rglob("*.rs"))
    paths += sorted((rust / "vendor/idevice").rglob("*.rs"))
    paths += [rust / "vendor/idevice/Cargo.toml",
              BACKEND / "Sources/CEiscueDeviceBackend/include/ncm_backend.h"]
    return {str(path.relative_to(BACKEND)): digest(path) for path in paths}


def archives(framework):
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    expected = {("ios", ""), ("ios", "simulator"), ("macos", "")}
    actual = set()
    files = {}
    source_header = BACKEND / "Sources/CEiscueDeviceBackend/include/ncm_backend.h"
    for library in info["AvailableLibraries"]:
        platform = (library["SupportedPlatform"], library.get("SupportedPlatformVariant", ""))
        if platform in actual or platform not in expected or library["SupportedArchitectures"] != ["arm64"]:
            raise ValueError("Unexpected or duplicate native platform")
        actual.add(platform)
        folder = framework / library["LibraryIdentifier"]
        archive = folder / library["LibraryPath"]
        header = folder / library["HeadersPath"] / "ncm_backend.h"
        module = header.with_name("module.modulemap")
        if digest(header) != digest(source_header):
            raise ValueError(f"Stale packaged header: {header}")
        if module.read_text() != 'module EiscueNativeBackend { header "ncm_backend.h" export * }\n':
            raise ValueError(f"Unexpected native module: {module}")
        for path in (archive, header, module):
            files[str(path.relative_to(framework))] = digest(path)
    if actual != expected:
        raise ValueError("Missing native platform")
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("record", "check"))
    parser.add_argument("--framework", type=Path, default=DEFAULT_FRAMEWORK)
    parser.add_argument("--toolchain")
    args = parser.parse_args()
    record_path = args.framework / "BUILD_MANIFEST.json"
    try:
        current = {"schema": 1, "sources": sources(), "artifacts": archives(args.framework)}
        if args.mode == "record":
            if not args.toolchain:
                raise ValueError("Recording requires --toolchain")
            current["toolchain"] = args.toolchain
            record_path.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
        else:
            saved = json.loads(record_path.read_text())
            for key, value in current.items():
                if saved.get(key) != value:
                    raise ValueError(f"Native {key} changed; rebuild the backend archives")
        print(f"Native archive {args.mode}: 3 arm64 platforms; source/header hashes match")
        return 0
    except (OSError, ValueError, KeyError) as error:
        print(f"Native archive check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
