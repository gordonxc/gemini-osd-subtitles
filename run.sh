#!/bin/bash
# Rebuild + re-bundle + launch the GeminiSubtitles app properly.
# Use this instead of `swift run` so TCC sees a stable bundle identity.

set -e
cd "$(dirname "$0")"

echo ">> Building release binary"
swift build -c release

echo ">> Updating bundle executable"
cp .build/release/GeminiSubtitles GeminiSubtitles.app/Contents/MacOS/GeminiSubtitles

echo ">> Re-signing bundle (adhoc)"
codesign --force --deep --sign - GeminiSubtitles.app

echo ">> Launching app via 'open' (proper bundle context for TCC)"
open -a "$(pwd)/GeminiSubtitles.app"

echo
echo "Done. If you do not get a 'System Audio Recording' permission prompt:"
echo "  1. Open System Settings → Privacy & Security → System Audio Recording"
echo "  2. Toggle 'Gemini Subtitles' ON"
echo "  3. Click the menu bar icon → Start"
