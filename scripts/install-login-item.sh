#!/bin/bash
# Run Audio Maker in the background at login (and right now) via a macOS LaunchAgent.
# Usage: scripts/install-login-item.sh            install / reinstall from this checkout
#        scripts/install-login-item.sh --uninstall
set -euo pipefail

LABEL="com.audio-maker.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/audio-maker.log"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
UV="$(command -v uv)"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$PLIST"
    echo "Removed Audio Maker login item."
    exit 0
fi

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$UV</string><string>run</string><string>--project</string><string>$DIR</string><string>audio-maker</string>
    </array>
    <key>WorkingDirectory</key><string>$DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$(dirname "$UV"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>AUDIO_MAKER_NO_BROWSER</key><string>1</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Audio Maker will start at login. Running now at http://127.0.0.1:${AUDIO_MAKER_PORT:-8765}"
echo "Logs: $LOG"
