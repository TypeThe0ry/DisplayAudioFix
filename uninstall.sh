#!/bin/sh
set -eu

if [ -x /usr/local/bin/displayaudiofix ]; then
  exec /usr/local/bin/displayaudiofix uninstall
fi

cd "$(dirname "$0")"
swift build -c release
exec .build/release/displayaudiofix uninstall
