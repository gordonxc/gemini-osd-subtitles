#!/bin/bash
# Launch the GeminiSubtitles app after rebuilding it.
# Delegates the build + bundle step to build.sh, then launches the .app
# via `open` so TCC sees a proper bundle context.

set -e
cd "$(dirname "$0")"

echo ">> Building (release) via build.sh"
./build.sh release

echo ">> Launching app via 'open' (proper bundle context for TCC)"
open -a "$(pwd)/GeminiSubtitles.app"

echo
echo "Done. If you do not get a 'System Audio Recording' permission prompt:"
echo "  1. Open System Settings → Privacy & Security → System Audio Recording"
echo "  2. Toggle 'Gemini Subtitles' ON"
echo "  3. Click the menu bar icon → Start"
