#!/usr/bin/env python3
"""Self-hosted Apple Silicon CI: pinned Xcode, isolated Kit cache and simulators.

Requires DEVELOPER_DIR, XcodeGen >= 2.45, Python 3, and an installed iOS runtime.
Never selects a global toolchain, installs software, or runs hardware acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def output(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True)


def check(*command):
    subprocess.run(command, cwd=ROOT, check=True)


def logged(directory, name, *command):
    check("bash", "Scripts/run-logged-check.sh", str(directory / (name + ".log")), *command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcode-major", required=True, choices=["26", "27"])
    parser.add_argument("--ios-version", required=True, choices=["26.3", "27.0"])
    parser.add_argument("--output", required=True, type=Path)
    options = parser.parse_args()
    directory = options.output.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("The committed device framework requires an Apple Silicon macOS runner")
    developer = os.environ.get("DEVELOPER_DIR", "")
    if not developer or not Path(developer).is_dir():
        raise RuntimeError("DEVELOPER_DIR must name the configured Xcode Contents/Developer directory")
    version = output("xcodebuild", "-version")
    if not re.search(r"^Xcode " + options.xcode_major + r"(?:\.|\s|$)", version):
        raise RuntimeError(f"Expected Xcode {options.xcode_major}, received {version.strip()}")
    if not options.ios_version.startswith(options.xcode_major + "."):
        raise RuntimeError("Use the matching iOS runtime for this toolchain")
    xcodegen = output("xcodegen", "--version")
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", xcodegen)
    if not match or tuple(map(int, match.groups())) < (2, 45, 0):
        raise RuntimeError("XcodeGen 2.45.0 or newer is required")
    runtimes = json.loads(output("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    runtime = next((item for item in runtimes if item.get("isAvailable")
                    and item["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
                    and (item["version"] == options.ios_version or item["version"].startswith(options.ios_version + "."))), None)
    if not runtime:
        raise RuntimeError(f"Install an available iOS {options.ios_version} simulator runtime before using this runner")
    (directory / "toolchain.txt").write_text(version + output("xcrun", "swift", "--version") + xcodegen
                                            + f"DEVELOPER_DIR={developer}\nruntime={runtime['identifier']}\n")
    logged(directory, "helper-tests", "python3", "-m", "unittest", "discover", "-s", "Scripts/Tests", "-p", "test_*.py")
    logged(directory, "native-archive-freshness", "python3", "Scripts/device-backend-artifacts.py", "check")
    logged(directory, "kit", "python3", "Scripts/test-swift-package.py", "--scratch-path",
           str(directory / "swiftpm"))
    logged(directory, "xcodegen", "xcodegen", "generate")
    logged(directory, "generated-project", "git", "diff", "--exit-code", "--", "Eiscue.xcodeproj")
    logged(directory, "hid-graph", "python3", "Scripts/check-hid-boundary.py")
    # Simulator signing is left enabled: unsigned app tests cannot use Keychain.
    base = ["xcodebuild", "-project", "Eiscue.xcodeproj", "-scheme", "Eiscue", "-derivedDataPath", str(directory / "DerivedData")]
    logged(directory, "release-build", *base, "-configuration", "Release", "-destination", "generic/platform=iOS Simulator", "ARCHS=arm64", "build")
    logged(directory, "hid-release-build", "xcodebuild", "-project", "Eiscue.xcodeproj", "-scheme", "EiscueHID",
           "-derivedDataPath", str(directory / "HIDDerivedData"), "-configuration", "Release",
           "-destination", "generic/platform=iOS Simulator", "ARCHS=arm64", "build")
    logged(directory, "hid-release-boundary", "python3", "Scripts/check-hid-boundary.py", "--app",
           str(directory / "HIDDerivedData/Build/Products/Release-iphonesimulator/EiscueHID.app"))
    devices = []
    try:
        for name, device_type in (("iphone", "iPhone-16e"), ("ipad", "iPad-Pro-11-inch-M5")):
            identifier = output("xcrun", "simctl", "create", f"Eiscue CI {options.xcode_major} {name} {os.getpid()}",
                                "com.apple.CoreSimulator.SimDeviceType." + device_type, runtime["identifier"]).strip()
            devices.append(identifier)
            check("xcrun", "simctl", "boot", identifier)
            check("xcrun", "simctl", "bootstatus", identifier, "-b")
            if name == "iphone":
                logged(directory, "hid-unit", "xcodebuild", "-project", "Eiscue.xcodeproj", "-scheme", "EiscueHID",
                       "-derivedDataPath", str(directory / "HIDDerivedData"), "-destination",
                       "platform=iOS Simulator,id=" + identifier, "-parallel-testing-enabled", "NO",
                       "-collect-test-diagnostics", "never", "-resultBundlePath", str(directory / "hid-unit.xcresult"),
                       "-only-testing:EiscueHIDAppTests", "test")
            command = [*base, "-destination", "platform=iOS Simulator,id=" + identifier,
                       "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", str(directory / (name + ".xcresult"))]
            if name == "ipad":
                command += ["-only-testing:EiscueUITests/SidebarUITests",
                            "-only-testing:EiscueUITests/ConversationManagementUITests",
                            "-only-testing:EiscueUITests/MessageSharingUITests"]
            # iPhone runs all app/UI cases. Hardware-only tests report explicit skips.
            logged(directory, name, "python3", "Scripts/run-with-model-fixture.py", "--log",
                   str(directory / (name + "-fixture.log")), "--", *command, "test")
            check("xcrun", "simctl", "shutdown", identifier)
    finally:
        original_failure = sys.exc_info()[0] is not None
        cleanup_failed = False
        for identifier in devices:
            subprocess.run(["xcrun", "simctl", "shutdown", identifier], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            result = subprocess.run(["xcrun", "simctl", "delete", identifier], cwd=ROOT)
            if result.returncode:
                cleanup_failed = True
                print(f"Could not remove CI simulator {identifier}: exit={result.returncode}", file=sys.stderr)
        if cleanup_failed and not original_failure:
            raise RuntimeError("CI simulator cleanup failed; test logs retain their own exit status")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode if error.returncode > 0 else 128 - error.returncode)
    except (OSError, RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(2)
