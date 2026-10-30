#!/bin/zsh
# Installs ScreenshotRename for the current user only (no sudo, no system files):
#   ~/Applications/ScreenshotRename.app
#   ~/Library/LaunchAgents/local.screenshot-rename.plist  (starts it at login)
set -euo pipefail
cd "$(dirname "$0")"

LABEL="local.screenshot-rename"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/ScreenshotRename.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh

# Stop a previous install, if running, including any copy launchd lost track of
# (an old copy would keep the hotkey and shadow the new build).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ScreenshotRename 2>/dev/null || true
for _ in {1..20}; do pgrep -x ScreenshotRename >/dev/null || break; sleep 0.1; done

mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
cp -R build/ScreenshotRename.app "$APP"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/ScreenshotRename</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo
echo "Installed. Press Cmd+Shift+7 to take a screenshot."
echo "First use: macOS will ask for Screen Recording permission for ScreenshotRename."
echo "Grant it in System Settings > Privacy & Security > Screen & System Audio Recording,"
echo "then run ./install.sh again so the permission takes effect."
echo "The permission is kept across future reinstalls and code changes."
