#!/usr/bin/env bash
# SDK-checked host fixtures; never loads XCTest frameworks or contacts a device.
set -euo pipefail
task_root=$(cd "$(dirname "$0")/.." && pwd)
fixture_build="$task_root/.build/owned-automation-fixtures"
automation_source="$task_root/Vendor/DeviceBackend/Sources/CEiscueAutomation/EiscueAutomation.m"
automation_headers="$task_root/Vendor/DeviceBackend/Sources/CEiscueAutomation/include"
mkdir -p "$fixture_build"

# Exercise the actual device implementation on the Mac ObjC runtime, substituting
# only platform imports/constants. All entry points, event bodies and guards are
# copied unchanged. Runtime classes below are fake, so no device IPC is possible.
python3 - "$automation_source" "$fixture_build/OwnedAutomationUnderTest.m" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
guard = '#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR'
ui_import = '#import <UIKit/UIKit.h>'
assert source.count(guard) == 1 and source.count(ui_import) == 1
source = source.replace(guard, '#if 1').replace(ui_import, '''#import <CoreGraphics/CoreGraphics.h>
#define UIScreenModeDidChangeNotification @"fixture.mode"
#define UIScreenDidConnectNotification @"fixture.connect"
#define UIScreenDidDisconnectNotification @"fixture.disconnect"''')
Path(sys.argv[2]).write_text(source)
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks \
    -framework Foundation -framework CoreGraphics \
    -I "$automation_headers" -I "$fixture_build" \
    "$task_root/Scripts/Tests/OwnedAutomationFixture.m" \
    -o "$fixture_build/OwnedAutomationFixture"
"$fixture_build/OwnedAutomationFixture"

# Ensure fixture portability never masks a real SDK ABI compilation error.
xcrun --sdk iphoneos clang -fsyntax-only -fobjc-arc -fblocks \
    -target arm64-apple-ios26.0 -Wno-deprecated-declarations \
    -I "$automation_headers" "$automation_source"
xcrun --sdk iphonesimulator clang -fsyntax-only -fobjc-arc -fblocks \
    -target arm64-apple-ios26.0-simulator \
    -I "$automation_headers" "$automation_source"
