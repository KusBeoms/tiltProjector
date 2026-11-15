#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/TiltProjector.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/TiltProjector" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --sign - "$APP"
echo "Built $APP  (open it; grant Screen Recording in System Settings, then relaunch)"
