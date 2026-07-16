#!/bin/bash
# A script that builds Axis and installs it to /Applications.
# Runs Archive → Export → overwrite /Applications/Axis.app, all in one go.
# Usage: from anywhere in the repo, run  ./install.sh  or  bash install.sh
set -euo pipefail

# Project settings
SCHEME="Axis"
APP_NAME="Axis.app"
TEAM_ID="YOUR_TEAM_ID"

# Treat the script's own location as the project root
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE_PATH="/tmp/Axis.xcarchive"
EXPORT_DIR="/tmp/Axis_export"
DEST="/Applications/$APP_NAME"

cd "$PROJECT_DIR"

echo "==> Archiving (Release)..."
xcodebuild -scheme "$SCHEME" -configuration Release -archivePath "$ARCHIVE_PATH" archive >/dev/null

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

echo "==> Installing to $DEST ..."
# If it's currently running, quit it first before overwriting
if pgrep -x "$SCHEME" >/dev/null; then
	echo "    Quitting running $SCHEME..."
	osascript -e "quit app \"$SCHEME\"" || true
	sleep 1
fi
rm -rf "$DEST"
cp -R "$EXPORT_DIR/$APP_NAME" "$DEST"

echo "==> Done. Installed $APP_NAME to /Applications."
