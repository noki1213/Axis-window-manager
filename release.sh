#!/bin/bash
# A script that builds the distribution zip attached to GitHub Releases.
# Builds a universal binary that runs on both Intel and Apple Silicon, ad-hoc signs it, and
# Packages it into dist/Axis-<version>.zip.
#
# Usage: ./release.sh
#
# Note: notarization isn't possible since there's no paid Apple Developer account.
# Anyone who downloads it will need to manually approve it on first launch (see the README).
set -euo pipefail

SCHEME="Axis"
APP_NAME="Axis.app"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/Axis_release_build"
cd "$PROJECT_DIR"

# Uses project.pbxproj's MARKETING_VERSION as the version number
VERSION="$(grep -m1 'MARKETING_VERSION' "$SCHEME.xcodeproj/project.pbxproj" | sed 's/.*= *//; s/;//' | tr -d ' ')"
OUT="dist/$SCHEME-$VERSION.zip"

echo "==> Building universal Release (arm64 + x86_64), version $VERSION ..."
rm -rf "$BUILD_DIR"
xcodebuild -scheme "$SCHEME" -configuration Release \
	-derivedDataPath "$BUILD_DIR" \
	CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
	CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM="" \
	ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
	build >/dev/null

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME"

# A universal build loses the linker's automatic signature, so it's explicitly ad-hoc signed.
# An app with no signature at all can't launch on Apple Silicon.
echo "==> Ad-hoc signing ..."
codesign --force --deep --sign - "$APP"
codesign --verify "$APP"

echo "==> Packaging ..."
mkdir -p dist
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"

echo "==> Verifying the packaged app ..."
CHECK_DIR="$(mktemp -d)"
ditto -x -k "$OUT" "$CHECK_DIR"
lipo -archs "$CHECK_DIR/$APP_NAME/Contents/MacOS/$SCHEME"
codesign --verify "$CHECK_DIR/$APP_NAME"
rm -rf "$CHECK_DIR"

echo "==> Done: $OUT"
echo "    Upload with:  gh release create v$VERSION $OUT --title \"v$VERSION\""
