#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/TiltProjector.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/TiltProjector" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sign with the stable local identity when it exists (see make-signing-cert.sh): the Screen Recording
# permission is tied to the signature, and an ad-hoc signature changes with every build.
KC="$HOME/Library/Keychains/tiltprojector-signing.keychain-db"
IDENTITY="TiltProjector Local Signing"
if [ -e "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p "" "$KC"
    codesign --force --sign "$IDENTITY" --keychain "$KC" "$APP"
    echo "signed with '$IDENTITY' (stable identity: Screen Recording permission survives rebuilds)"
else
    codesign --force --sign - "$APP"
    echo "signed ad-hoc; run scripts/make-signing-cert.sh once so the permission survives rebuilds"
fi
codesign --verify --strict "$APP"
echo "Built $APP  (open it; grant Screen Recording in System Settings, then relaunch)"
