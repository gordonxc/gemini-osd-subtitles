#!/bin/bash
# Publish a new Sparkle-aware release of Gemini Subtitles.
#
# Flow:
#   1. Verify Info.plist CFBundleShortVersionString matches the arg.
#   2. ./build.sh release
#   3. Zip the .app via ditto (preserves bundle structure + macOS metadata).
#   4. Sign the zip with Sparkle's EdDSA key (read from the Keychain).
#   5. Create a GitHub Release and upload the zip.
#   6. Append a new <item> to appcast.xml, commit, push.
#
# Prerequisites:
#   - ./setup-cert.sh has been run (code-signing identity exists).
#   - Sparkle EdDSA keypair generated once:
#       <sparkle>/bin/generate_keys
#     The pubkey it prints must match Info.plist's SUPublicEDKey. The priv
#     key is stored in your login Keychain — never on disk. To transfer it
#     to another machine use `generate_keys -x <file>` (then import there
#     with `-f`), or just keep publishing from this one.
#   - `gh` is installed and authenticated.
#   - sign_update / generate_keys from Sparkle.framework/bin on your PATH,
#     or set SPARKLE_BIN to that directory.
#
# Usage: ./publish-release.sh 0.7.0 ["Release notes..."]
set -euo pipefail

cd "$(dirname "$0")"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version> [release_notes]" >&2
  echo "Example: $0 0.7.0 \"Bilingual OSD fix\"" >&2
  exit 1
fi

VERSION="$1"
NOTES="${2:-Gemini Subtitles ${VERSION}}"
TAG="v${VERSION}"
APP_NAME="GeminiSubtitles"
APP_BUNDLE="${APP_NAME}.app"
ZIP_NAME="${APP_NAME}-v${VERSION}.zip"
INFO_PLIST="Sources/GeminiSubtitles/Assets/Info.plist"
APPCAST="appcast.xml"

# Locate sign_update. Prefer PATH, fall back to the SPM-extracted copy.
SPARKLE_BIN="${SPARKLE_BIN:-}"
SIGN_UPDATE=""
if [[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN/sign_update" ]]; then
  SIGN_UPDATE="$SPARKLE_BIN/sign_update"
elif command -v sign_update >/dev/null 2>&1; then
  SIGN_UPDATE="$(command -v sign_update)"
else
  CANDIDATE="$(pwd)/.build/artifacts/sparkle/Sparkle/bin/sign_update"
  if [[ -x "$CANDIDATE" ]]; then
    SIGN_UPDATE="$CANDIDATE"
  fi
fi
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "!! sign_update not found." >&2
  echo "!! Run 'swift build' first (extracts Sparkle.framework/bin), or" >&2
  echo "!! set SPARKLE_BIN to your Sparkle.framework/bin directory." >&2
  exit 1
fi

# --- 1. Version sanity check --------------------------------------------------
# Fail fast if the user forgot to bump Info.plist. Plutil is preinstalled on
# macOS and avoids requiring a third-party Plist parser.
PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  echo "!! Info.plist CFBundleShortVersionString is \"${PLIST_VERSION}\"," >&2
  echo "!! but you asked to publish \"${VERSION}\"." >&2
  echo "!! Bump the version in $INFO_PLIST first." >&2
  exit 1
fi

# --- 2. Build ----------------------------------------------------------------
echo ">> Building release…"
./build.sh release

# --- 3. Zip ------------------------------------------------------------------
echo ">> Zipping ${ZIP_NAME}…"
# --keepParent preserves the .app directory wrapper so the bundle unpacks
# correctly on download. Remove any stale zip from a prior attempt.
rm -f "$ZIP_NAME"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"
ZIP_LENGTH="$(stat -f%z "$ZIP_NAME")"

# --- 4. EdDSA-sign the archive (priv key read from Keychain) -----------------
echo ">> Signing archive with Sparkle EdDSA key…"
# Output looks like:  sparkle:edSignature="<base64>" length="<bytes>"
# Pull just the base64 signature out of the first quoted field.
SIGN_LINE="$("$SIGN_UPDATE" "$ZIP_NAME")"
ED_SIGNATURE="$(echo "$SIGN_LINE" \
  | grep -oE 'sparkle:edSignature="[^"]+"' \
  | sed -E 's/^sparkle:edSignature="(.+)"$/\1/')"
if [[ -z "$ED_SIGNATURE" ]]; then
  echo "!! Failed to parse EdDSA signature from sign_update output:" >&2
  echo "!!   $SIGN_LINE" >&2
  exit 1
fi

# --- 5. GitHub Release -------------------------------------------------------
echo ">> Creating GitHub Release ${TAG}…"
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "   Release ${TAG} already exists; re-uploading asset."
  gh release upload "$TAG" "$ZIP_NAME" --clobber
else
  gh release create "$TAG" "$ZIP_NAME" \
    --title "${TAG}" \
    --notes "${NOTES}"
fi

# Resolve the canonical asset download URL (the browser-redirect URL works
# fine as a Sparkle enclosure).
OWNER_REPO="$(git remote get-url origin \
  | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
ASSET_URL="https://github.com/${OWNER_REPO}/releases/download/${TAG}/${ZIP_NAME}"

# --- 6. Append to appcast.xml ------------------------------------------------
echo ">> Updating ${APPCAST}…"
# Defensive: refuse to clobber a missing/malformed feed.
if [[ ! -f "$APPCAST" ]]; then
  echo "!! $APPCAST not found. Restore it from git before publishing." >&2
  exit 1
fi
xmllint --noout "$APPCAST"

# If an entry for this version already exists, drop it first so republishing
# is idempotent.
python3 - "$APPCAST" "$VERSION" <<'PY'
import re, sys
path, version = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    xml = f.read()
# Remove any existing <item> whose sparkle:version matches this version.
pattern = re.compile(
    r'<item>\s*<title>(?:(?!</title>).)*?</title>\s*'
    r'<sparkle:version>%s</sparkle:version>.*?</item>\s*' % re.escape(version),
    re.DOTALL)
xml = pattern.sub('', xml)
with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
PY

# Determine today's date for <pubDate> (RFC 822).
PUB_DATE="$(date -R)"

# Compose the new <item>. Sparkle requires: enclosure url + length + signature;
# sparkle:version must be unique and monotonic for the upgrade check.
NEW_ITEM="$(cat <<EOF
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:edSignature>${ED_SIGNATURE}</sparkle:edSignature>
            <description><![CDATA[${NOTES}]]></description>
            <enclosure
                url="${ASSET_URL}"
                sparkle:edSignature="${ED_SIGNATURE}"
                length="${ZIP_LENGTH}"
                type="application/octet-stream" />
        </item>
EOF
)"

# Insert the new <item> right before the first existing <item> (so newest
# release is always first AND channel metadata stays above the items). If no
# <item> exists yet, insert before </channel>.
python3 - "$APPCAST" "$NEW_ITEM" <<'PY'
import re, sys
path, item = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    xml = f.read()
m = re.search(r'<item>', xml)
if m:
    idx = m.start()
else:
    m = re.search(r'</channel>', xml)
    if not m:
        raise SystemExit("appcast has neither <item> nor </channel>")
    idx = m.start()
xml = xml[:idx] + item + "\n        " + xml[idx:]
with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
PY

xmllint --noout "$APPCAST"

echo ">> Committing ${APPCAST}…"
git add "$APPCAST"
git commit -m "chore: appcast for ${VERSION}" >/dev/null
git push origin main

echo ""
echo "✓ Published ${VERSION}"
echo "  Asset:     ${ASSET_URL}"
echo "  Appcast:   ${APPCAST}"
echo "  Signature: ${ED_SIGNATURE}"
