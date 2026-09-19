#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build -c release
exec .build/release/displayaudiofix install
