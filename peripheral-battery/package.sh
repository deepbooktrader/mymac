#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
folder="PeripheralBattery-v$version"
mkdir -p "$stage/$folder"
ditto --norsrc build/PeripheralBattery.app "$stage/$folder/外设电量.app"
cp docs/INSTALL.txt "$stage/$folder/安装说明.txt"
xattr -cr "$stage/$folder/外设电量.app"
codesign --verify --verbose "$stage/$folder/外设电量.app"
archive="build/PeripheralBattery-v$version-macOS-arm64.zip"
ditto -c -k --norsrc --keepParent "$stage/$folder" "$archive"
shasum -a 256 "$archive"
