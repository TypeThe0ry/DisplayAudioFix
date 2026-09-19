#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build -c release

BIN="$HOME/.local/bin/displayaudiofix"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/com.displayaudiofix.agent.plist"
mkdir -p "$HOME/.local/bin" "$AGENT_DIR"
cp .build/release/displayaudiofix "$BIN"
chmod 755 "$BIN"

sed "s|__DISPLAYAUDIOFIX_BINARY__|$BIN|g" com.displayaudiofix.agent.plist > "$AGENT"
chmod 644 "$AGENT"

UID_VALUE="$(id -u)"
launchctl bootout "gui/$UID_VALUE/com.displayaudiofix.agent" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$AGENT"
launchctl kickstart -k "gui/$UID_VALUE/com.displayaudiofix.agent"

echo "DisplayAudioFix user agent installed and running."
echo "Binary: $BIN"
echo "Agent:  $AGENT"
echo "This user agent cannot restart the system coreaudiod service; use install.sh after sudo authorization for full recovery privileges."
