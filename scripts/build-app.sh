#!/bin/bash
# Builds Murmur.app into build/
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Murmur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Murmur.icns "$APP/Contents/Resources/Murmur.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign with a stable identity so the Accessibility/Microphone grants survive
# rebuilds. Ad-hoc signatures ("-") change every build, which makes macOS
# silently drop the permissions.
IDENTITY="${MURMUR_SIGN_IDENTITY:-Apple Development: Pradeep Jain (JH687FXFDY)}"
if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "WARNING: identity '$IDENTITY' not found; used ad-hoc signing." >&2
    echo "         Permissions will need re-granting after every rebuild." >&2
fi
echo "Built $APP"
