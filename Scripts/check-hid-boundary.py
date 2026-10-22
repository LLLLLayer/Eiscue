#!/usr/bin/env python3
"""Verify the HID product graph and, optionally, a signed built HID app."""

import argparse
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN_MODULES = ("EiscueDeviceKit", "EiscueDeviceBackend", "CEiscueDeviceBackend", "EiscueNativeBackend", "CEiscueAutomation", "PhoneAgentNCM", "CNCMBackend", "NCMNativeBackend")


def command(*arguments):
    return subprocess.run(arguments, cwd=ROOT, check=True, capture_output=True).stdout


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_package():
    package = json.loads(command("swift", "package", "dump-package"))
    targets = {target["name"]: target for target in package["targets"]}
    product = next(product for product in package["products"] if product["name"] == "EiscueHIDKit")
    pending = list(product["targets"])
    visited = set()
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        require(name not in FORBIDDEN_MODULES, f"HID product depends on {name}")
        for dependency in targets[name]["dependencies"]:
            if "byName" in dependency:
                pending.append(dependency["byName"][0])
            elif "target" in dependency:
                pending.append(dependency["target"][0])
            else:
                raise ValueError(f"Review external dependency in HID target {name}: {dependency}")
    require("EiscueDeviceCore" in visited, "HID product must use the shared device core")
    print("HID target closure: " + ", ".join(sorted(visited)))


def check_entitlements(bundle, unsigned=False):
    try:
        entitlements = plistlib.loads(command("codesign", "-d", "--entitlements", ":-", str(bundle)))
    except subprocess.CalledProcessError as error:
        if unsigned and b"code object is not signed at all" in error.stderr:
            print(f"Unsigned {bundle.name}: no signature entitlements to inspect")
            return
        raise
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    if not entitlements and info.get("DTPlatformName") == "iphonesimulator":
        # Simulator signatures are ad hoc; Xcode embeds the effective simulated
        # entitlements in the executable instead of its code-signing blob.
        data = (bundle / info["CFBundleExecutable"]).read_bytes()
        require(data[:4] == bytes.fromhex("cffaedfe"), "Expected an arm64 Mach-O simulator binary")
        offset = 32
        for _ in range(struct.unpack_from("<I", data, 16)[0]):
            kind, size = struct.unpack_from("<II", data, offset)
            if kind == 0x19:  # LC_SEGMENT_64
                for index in range(struct.unpack_from("<I", data, offset + 64)[0]):
                    section = offset + 72 + index * 80
                    if data[section:section + 16].rstrip(b"\0") == b"__entitlements":
                        length = struct.unpack_from("<Q", data, section + 40)[0]
                        start = struct.unpack_from("<I", data, section + 48)[0]
                        entitlements = plistlib.loads(data[start:start + length])
            offset += size
    require("com.apple.developer.networking.networkextension" not in entitlements,
            f"Network Extension entitlement in {bundle.name}")
    require(entitlements.get("com.apple.security.application-groups") == ["group.org.eiscue.hid"],
            f"HID App Group is missing or shared with the full app in {bundle.name}")


def check_project():
    project = json.loads(command("plutil", "-convert", "json", "-o", "-", str(ROOT / "Eiscue.xcodeproj/project.pbxproj")))
    objects = project["objects"]
    app = next(value for value in objects.values() if value.get("isa") == "PBXNativeTarget" and value.get("name") == "EiscueHID")
    products = {objects[item]["productName"] for item in app.get("packageProductDependencies", [])}
    require("EiscueHIDKit" in products, "HID app must link the HID product")
    require(not products.intersection(FORBIDDEN_MODULES), "HID app links a full backend product")
    embedded = {objects[objects[item]["target"]]["name"] for item in app.get("dependencies", [])}
    require(embedded == {"EiscueHIDBroadcast"}, f"Unexpected HID app target dependencies: {embedded}")
    print("HID project dependencies: " + ", ".join(sorted(products | embedded)))


def check_app(app, unsigned=False):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == "org.eiscue.hid", "Expected the EiscueHID app")
    require(info.get("EiscueScreenBroadcastAppGroup") == "group.org.eiscue.hid", "Wrong HID screen store")
    require(not (app / "LocalTunnel").exists(), "HID app contains the VPN reflector resources")
    extensions = sorted((app / "PlugIns").glob("*.appex"))
    require(len(extensions) == 1, "HID app must embed only its ReplayKit extension")
    extension_info = plistlib.loads((extensions[0] / "Info.plist").read_bytes())
    require(extension_info["CFBundleIdentifier"] == "org.eiscue.hid.broadcast", "Wrong broadcast extension")
    require(extension_info.get("EiscueScreenBroadcastAppGroup") == "group.org.eiscue.hid", "Wrong extension screen store")
    require(extension_info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.broadcast-services-upload",
            "Unexpected extension type")
    for bundle in [app, *extensions]:
        check_entitlements(bundle, unsigned=unsigned)
    # Debug builds can place app code in a separate dylib. Inspect every Mach-O,
    # including embedded frameworks, instead of checking only the launch stub.
    magic = {bytes.fromhex(value) for value in ("feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
    for executable in app.rglob("*"):
        if not executable.is_file():
            continue
        with executable.open("rb") as source:
            if source.read(4) not in magic:
                continue
        symbols = command("xcrun", "nm", "-a", str(executable)).decode(errors="replace")
        libraries = command("xcrun", "otool", "-L", str(executable)).decode(errors="replace")
        for forbidden in (*FORBIDDEN_MODULES, "NetworkExtension.framework"):
            require(forbidden not in symbols + libraries, f"Forbidden linkage {forbidden} in {executable.name}")
    print(f"HID {'unsigned linkage/structure' if unsigned else 'app boundary'} verified: {app}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Signed EiscueHID.app to inspect (simulator or device)")
    parser.add_argument("--unsigned", action="store_true", help="Allow an unsigned device build; signature entitlements remain unverified")
    args = parser.parse_args()
    try:
        check_package()
        check_project()
        if args.app:
            check_app(args.app.resolve(), unsigned=args.unsigned)
    except (ValueError, KeyError, StopIteration, OSError, struct.error, subprocess.CalledProcessError) as error:
        print(f"HID boundary check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
