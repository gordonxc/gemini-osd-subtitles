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

# Re-sign the bundle with a stable code-signing identity so TCC permissions
# (Screen Recording / System Audio Recording) persist across rebuilds.
# Ad-hoc signing (cdhash-based) would force re-approval every build.
#
# Identity source:
#   1. $SIGN_IDENTITY env var (explicit override)
#   2. "GeminiSubtitles Dev" — created by ./setup-cert.sh (one-time)
#
# If the identity is missing, fail loudly instead of silently falling back
# to ad-hoc — that way you never accidentally ship a build that resets TCC.
SIGN_IDENTITY="${SIGN_IDENTITY:-GeminiSubtitles Dev}"
if ! security find-identity -p codesigning -v 2>/dev/null \
     | grep -qF "$SIGN_IDENTITY"; then
  echo "!! Code-signing identity \"$SIGN_IDENTITY\" not found." >&2
  echo "!! Run ./setup-cert.sh once to create it, or set SIGN_IDENTITY." >&2
  exit 1
fi
echo ">> Code signing (identity=${SIGN_IDENTITY}, identifier=${BUNDLE_ID})"
codesign --force --deep \
  --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  "$APP_BUNDLE"

# Strip the quarantine flag so Gatekeeper doesn't block the unsigned bundle.
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

echo ">> Done: $(pwd)/${APP_BUNDLE}"

if [[ "$MODE" == "run" ]]; then
  echo ">> Launching…"
  open "$APP_BUNDLE"
fi
