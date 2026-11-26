#!/bin/bash
# Build Telltale.app
#
#   ./build.sh              build for this Mac            -> build/Telltale.app
#   ./build.sh --universal  build for Apple Silicon + Intel
#   ./build.sh --install    build, copy to ~/Applications and launch
#   ./build.sh --zip        build universal and package build/Telltale-<version>.zip (used for releases)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Telltale"
APP="build/$APP_NAME.app"
MIN_MACOS="14.0"
UNIVERSAL=0; INSTALL=0; ZIP=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install)   INSTALL=1 ;;
    --zip)       ZIP=1; UNIVERSAL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() { # $1 = arch, $2 = output
  swiftc -O -swift-version 5 -target "$1-apple-macos$MIN_MACOS" Sources/*.swift -o "$2"
}

if [ "$UNIVERSAL" = 1 ]; then
  compile arm64  "build/$APP_NAME-arm64"
  compile x86_64 "build/$APP_NAME-x86_64"
  lipo -create "build/$APP_NAME-arm64" "build/$APP_NAME-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"
  rm -f "build/$APP_NAME-arm64" "build/$APP_NAME-x86_64"
else
  compile "$(uname -m)" "$APP/Contents/MacOS/$APP_NAME"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Ad-hoc signature (no Apple Developer ID). See README → "First launch" for Gatekeeper.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"

if [ "$ZIP" = 1 ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  (cd build && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME-$VERSION.zip")
  echo "Packaged build/$APP_NAME-$VERSION.zip"
fi

if [ "$INSTALL" = 1 ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/$APP_NAME.app"
  echo "Installed to ~/Applications/$APP_NAME.app"
fi
