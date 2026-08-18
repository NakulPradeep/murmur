#!/bin/bash
# Produces dist/Murmur-<version>.zip for a GitHub Release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
scripts/build-app.sh

mkdir -p dist
ZIP="dist/Murmur-$VERSION.zip"
rm -f "$ZIP"

# ditto, not zip: it preserves the code signature and resource forks that a
# plain zip silently corrupts, which makes the app fail to launch.
ditto -c -k --sequesterRsrc --keepParent build/Murmur.app "$ZIP"

echo "Built $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo
codesign -dv --verbose=2 build/Murmur.app 2>&1 | grep -E "^Authority" | head -2
if ! spctl -a -vv build/Murmur.app >/dev/null 2>&1; then
cat <<'WARN'

NOTE: this build is not notarized, so Gatekeeper will warn on other Macs.
Users must right-click -> Open the first time. To remove that warning you need
an Apple Developer Program membership, then sign with Developer ID and notarize:

  codesign --force --deep --options runtime --sign "Developer ID Application: NAME (TEAMID)" build/Murmur.app
  xcrun notarytool submit dist/Murmur-VERSION.zip --apple-id EMAIL --team-id TEAMID --wait
  xcrun stapler staple build/Murmur.app
WARN
fi
