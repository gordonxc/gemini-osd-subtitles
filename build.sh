#!/bin/bash
# Builds the Gemini Subtitles macOS app and produces a runnable .app bundle.
# Usage:
#   ./build.sh            # debug build
#   ./build.sh release    # release (optimized) build
#   ./build.sh run        # build + open the .app
set -euo pipefail

cd "$(dirname "$0")"

MODE="${1:-debug}"
APP_NAME="GeminiSubtitles"
APP_BUNDLE="${APP_NAME}.app"
# Stable bundle identifier used for code signing and TCC tracking.
# Must match CFBundleIdentifier in Info.plist so the System Audio
# Recording permission granted by the user sticks across rebuilds.
BUNDLE_ID="com.gemini-subtitles"

case "$MODE" in
  release)
    echo ">> Building (release)…"
    swift build -c release
    BIN=".build/release/${APP_NAME}"
    ;;
  debug|run)
    echo ">> Building (debug)…"
    swift build
    BIN=".build/debug/${APP_NAME}"
    ;;
  *)
    echo "Unknown mode: $MODE (use: debug | release | run)"
    exit 1
    ;;
esac

echo ">> Packaging ${APP_BUNDLE}…"
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp "$BIN" "${APP_BUNDLE}/Contents/MacOS/"
cp "Sources/GeminiSubtitles/Assets/Info.plist" "${APP_BUNDLE}/Contents/"

# Re-sign the bundle so the code-signing identifier matches CFBundleIdentifier.
# SwiftPM ad-hoc signs with a hash-suffixed identifier that changes every build.
# Using --identifier at least makes the identifier stable.
#
# NOTE: ad-hoc signed apps still have a cdhash-based designated requirement, so
# TCC may require re-approval of System Audio Recording after each rebuild. To
# get stable approval across rebuilds, sign with a real Developer ID certificate
# or create a self-signed cert in Keychain Access and pass its name to --sign.
echo ">> Code signing (adhoc, identifier=${BUNDLE_ID})…"
codesign --force --deep \
  --sign - \
  --identifier "$BUNDLE_ID" \
  "$APP_BUNDLE"

# Strip the quarantine flag so Gatekeeper doesn't block the unsigned bundle.
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

echo ">> Done: $(pwd)/${APP_BUNDLE}"

if [[ "$MODE" == "run" ]]; then
  echo ">> Launching…"
  open "$APP_BUNDLE"
fi
