#!/bin/zsh
set -eu
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "${0:A:h:h}"
fixture_app="$PWD/build/WindowBadgeFixture.app"
mkdir -p "$fixture_app/Contents/MacOS"
/usr/bin/swiftc -parse-as-library -framework AppKit Tests/Fixtures/badge-window.swift -o "$fixture_app/Contents/MacOS/window-badge-fixture"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.timezone.lab.badge-fixture</string>
<key>CFBundleExecutable</key><string>window-badge-fixture</string>
<key>CFBundleName</key><string>Window Badge Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign "${SIGN_IDENTITY:--}" "$fixture_app"
print -r -- "$fixture_app"
