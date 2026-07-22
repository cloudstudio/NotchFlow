#!/bin/bash
# Builds NotchFlow.app from the release products.
#
#   Packaging/build-app.sh [--install]
#
#   --install            Copy the result to ~/Applications/NotchFlow.app
#
# Environment:
#   CODESIGN_IDENTITY    "Developer ID Application: ..." for distribution.
#                        Defaults to ad-hoc signing for local use.
#   NOTARY_PROFILE       notarytool keychain profile; when set the app is
#                        zipped, submitted with --wait and stapled.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=".build/package"
APP="$OUT/NotchFlow.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c release

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp .build/release/NotchFlow "$APP/Contents/MacOS/NotchFlow"
cp .build/release/notchflow-hook "$APP/Contents/Helpers/notchflow-hook"
cp .build/release/notchflow-install "$APP/Contents/Helpers/notchflow-install"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Helpers/notchflow-hook"
codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Helpers/notchflow-install"
codesign --force --sign "$IDENTITY" --options runtime "$APP"
echo "Signed with identity: $IDENTITY"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$APP" "$OUT/NotchFlow.zip"
    xcrun notarytool submit "$OUT/NotchFlow.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    echo "Notarized and stapled"
fi

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/NotchFlow.app
    ditto "$APP" ~/Applications/NotchFlow.app
    echo "Installed at ~/Applications/NotchFlow.app"
    echo "Run: ~/Applications/NotchFlow.app/Contents/Helpers/notchflow-install"
fi

echo "Done: $APP"
