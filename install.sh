#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build -c release
BIN="$PWD/.build/release/displayaudiofix"

if [ "$(id -u)" -ne 0 ]; then
  echo "DisplayAudioFix needs administrator authorization to install /usr/local/bin and /Library/LaunchDaemons." >&2
  echo "Enter your macOS login password when sudo asks. Press Ctrl-C to cancel; do not suspend this command." >&2
  if ! sudo -v; then
    echo "sudo authorization failed; nothing was installed." >&2
    exit 1
  fi
  exec sudo "$BIN" install
fi

exec "$BIN" install
