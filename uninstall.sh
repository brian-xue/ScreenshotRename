#!/bin/zsh
# Removes everything install.sh created, plus the app's preferences and its
# Screen Recording permission entry.
set -uo pipefail

LABEL="local.screenshot-rename"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x ScreenshotRename 2>/dev/null
rm -f  "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ScreenshotRename.app"
defaults delete "$LABEL" 2>/dev/null
rm -f  "$HOME/Library/Preferences/$LABEL.plist"
tccutil reset ScreenCapture "$LABEL" >/dev/null 2>&1
rm -rf "$HOME/Library/Application Support/ScreenshotRename"   # local signing keychain
rm -rf "$(dirname "$0")/build"

echo "ScreenshotRename uninstalled."
