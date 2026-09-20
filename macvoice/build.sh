#!/bin/sh
# Builds ./macvoice (CLI: --demo/--text/--snapshot) and ./macvoice.app (voice mode).
#
# Why the .app: a tool launched from a terminal inherits THAT terminal's privacy
# declarations. VS Code and Terminal do not declare speech recognition, so voice mode is
# killed on launch. An .app bundle is its own responsible process and carries its own keys.
# The ad-hoc signature is required for macOS to honour those keys at all.
set -e
cd "$(dirname "$0")"

swiftc -O -swift-version 5 main.swift ui.swift menus.swift browser.swift windows.swift parse.swift policy.swift task.swift dom.swift profiles.swift -o macvoice \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign -s - --force --timestamp=none macvoice

APP=macvoice.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp macvoice "$APP/Contents/MacOS/macvoice"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string macvoice' \
  -c 'Add :CFBundlePackageType string APPL' \
  -c 'Add :CFBundleShortVersionString string 0.1' \
  -c 'Add :LSUIElement bool true' "$APP/Contents/Info.plist" >/dev/null
# The designated requirement is pinned to the identifier, NOT the default build hash, so the
# Accessibility/Microphone permissions you grant survive a rebuild instead of silently breaking.
codesign -s - --force --deep --timestamp=none -i local.macvoice \
  -r='designated => identifier "local.macvoice"' "$APP"
echo "built $(pwd)/macvoice and $(pwd)/$APP"
