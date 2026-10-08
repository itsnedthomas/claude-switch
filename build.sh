#!/bin/bash
# Builds "Claude Switch.app". Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/Claude Switch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeSwitch "$APP/Contents/MacOS/ClaudeSwitch"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x ClaudeSwitch || true
  sleep 1
  rm -rf "$HOME/Applications/Claude Switch.app"   # older installs lived here
  rm -rf "/Applications/Claude Switch.app"
  cp -R "$APP" /Applications/
  open "/Applications/Claude Switch.app"
  echo "Installed and launched /Applications/Claude Switch.app"
fi
