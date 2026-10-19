#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="build/PeripheralBattery.app"
mkdir -p "$APP/Contents/MacOS" build/module-cache
cp Resources/Info.plist "$APP/Contents/Info.plist"
xcrun swiftc -target arm64-apple-macos14.0 -swift-version 5 -O -module-cache-path build/module-cache \
  Sources/PeripheralBattery.swift -o "$APP/Contents/MacOS/PeripheralBattery.new" \
  -framework Cocoa -framework IOKit -framework UserNotifications \
  -framework ServiceManagement -framework SwiftUI
mv "$APP/Contents/MacOS/PeripheralBattery.new" "$APP/Contents/MacOS/PeripheralBattery"
xattr -cr "$APP"
# iCloud may attach Finder metadata after the app bundle is first created.
if ! codesign --force --sign - "$APP"; then
  xattr -cr "$APP"
  codesign --force --sign - "$APP"
fi
codesign --verify --verbose "$APP"
"$APP/Contents/MacOS/PeripheralBattery" --check
printf '\nBuilt: %s\n' "$PWD/$APP"
