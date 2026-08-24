#!/bin/bash
# A script that builds Axis and installs it to /Applications.
# Runs Archive → Export → overwrite /Applications/Axis.app, all in one go.
# Usage: from anywhere in the repo, run  ./install.sh  or  bash install.sh
#
# About signing:
#   Place a .env at the repo root with TEAM_ID="XXXXXXXXXX" written in it, and that
#   Signs and installs it with an Apple Developer Team. Since the signature is stable,
#   makes the Accessibility permission less likely to get revoked on rebuilds.
#   Without a .env, it builds unsigned (ad-hoc). Apple Developer
#   this method works for installing it even without an account.
set -euo pipefail

# Project settings
SCHEME="Axis"
APP_NAME="Axis.app"

# Treat the script's own location as the project root
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE_PATH="/tmp/Axis.xcarchive"
EXPORT_DIR="/tmp/Axis_export"
DEST="/Applications/$APP_NAME"

cd "$PROJECT_DIR"

# Read TEAM_ID from local, untracked config
[ -f .env ] && source .env
TEAM_ID="${TEAM_ID:-}"

if [ -n "$TEAM_ID" ]; then
	echo "==> Archiving (Release, signed with team $TEAM_ID)..."
	xcodebuild -scheme "$SCHEME" -configuration Release \
		-archivePath "$ARCHIVE_PATH" \
		DEVELOPMENT_TEAM="$TEAM_ID" \
		archive >/dev/null

	echo "==> Exporting..."
	EXPORT_PLIST="$(mktemp)"
	cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
	rm -rf "$EXPORT_DIR"
	xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$EXPORT_PLIST" >/dev/null
	BUILT_APP="$EXPORT_DIR/$APP_NAME"
else
	echo "==> Archiving (Release, unsigned)..."
	echo "    No TEAM_ID in .env; building unsigned."
	BUILD_DIR="/tmp/Axis_build"
	rm -rf "$BUILD_DIR"
	xcodebuild -scheme "$SCHEME" -configuration Release \
		-derivedDataPath "$BUILD_DIR" \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM="" \
		build >/dev/null
	BUILT_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME"
fi

echo "==> Installing to $DEST ..."
# If it's currently running, quit it first before overwriting
if pgrep -x "$SCHEME" >/dev/null; then
	echo "    Quitting running $SCHEME..."
	osascript -e "quit app \"$SCHEME\"" || true
	sleep 1
fi
rm -rf "$DEST"
cp -R "$BUILT_APP" "$DEST"

echo "==> Launching $APP_NAME ..."
open "$DEST"

echo "==> Done. Installed and launched $APP_NAME."
