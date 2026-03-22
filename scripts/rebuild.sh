#!/bin/bash
# Rebuild and restart phatmux app

set -e

cd "$(dirname "$0")/.."

# Kill existing app if running
pkill -9 -f "phatmux" 2>/dev/null || true

# Build
swift build

# Copy to app bundle
cp .build/debug/phatmux .build/debug/phatmux.app/Contents/MacOS/

# Open the app
open .build/debug/phatmux.app
