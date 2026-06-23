#!/bin/bash
# One-time setup: create a self-signed code-signing certificate so TCC
# permissions (Screen Recording / System Audio Recording) persist across
# rebuilds.
#
# Without this, every `./build.sh` produces a new cdhash and macOS asks you
# to re-grant permissions in System Settings. With it, the designated
# requirement is certificate-based and stable, so the first approval sticks.
#
# Usage:
#   ./setup-cert.sh            # default name "GeminiSubtitles Dev"
#   ./setup-cert.sh "My Name"  # custom name
#
# This creates the cert in your LOGIN keychain. After running once, build.sh
# will pick it up automatically (or set SIGN_IDENTITY=... to override).

set -euo pipefail

CERT_NAME="${1:-GeminiSubtitles Dev}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if [[ ! -f "$KEYCHAIN" ]]; then
  echo "!! Login keychain not found at $KEYCHAIN"
  exit 1
fi

# Re-run support: if a cert with this name already exists but is invalid for
# codesigning (or just to regenerate cleanly), purge the prior cert + key
# first. `find-identity -p codesigning` lists identities that match by CN
# regardless of whether they pass the policy, so we use it to detect any
# pre-existing entry (including broken ones).
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
     | grep -qF "$CERT_NAME"; then
  echo ">> Removing prior \"$CERT_NAME\" cert (if any) before regenerating"
  # Loop because delete-certificate exits non-zero once no match remains, and
  # there may be a stale cert + a separate key item.
  while security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" 2>/dev/null; do
    :
  done
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Use an explicit openssl config rather than -addext. macOS's codesigning
# policy requires BOTH keyUsage=digitalSignature AND
# extendedKeyUsage=codeSigning; missing keyUsage produces the cryptic
# "(Invalid Key Usage for policy)" error from `codesign --sign`.
cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext

[dn]
CN = ${CERT_NAME}

[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

echo ">> Generating self-signed code-signing certificate (\"$CERT_NAME\")"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" \
  -out "$WORK/cert.pem" \
  -days 3650 \
  -config "$WORK/openssl.cnf" \
  >/dev/null 2>&1

echo ">> Verifying certificate extensions"
openssl x509 -in "$WORK/cert.pem" -noout -text \
  | grep -A1 'Key Usage' | head -3 || true

echo ">> Importing private key into login keychain"
security import "$WORK/key.pem" \
  -k "$KEYCHAIN" \
  -t priv \
  -T /usr/bin/codesign \
  -A

echo ">> Importing certificate into login keychain"
security import "$WORK/cert.pem" \
  -k "$KEYCHAIN" \
  -t cert \
  -T /usr/bin/codesign

echo ">> Marking certificate as trusted for code signing (requires sudo)"
sudo security add-trusted-cert -d \
  -r trustRoot \
  -k "$KEYCHAIN" \
  "$WORK/cert.pem"

echo
echo ">> Verifying identity is usable for codesigning…"
# `-v` filters to identities that actually pass the codesigning policy.
# An entry that's in the keychain but fails the policy would be omitted
# from the `-v` list (and shown separately without -v).
if security find-identity -p codesigning -v "$KEYCHAIN" \
     | grep -F "$CERT_NAME"; then
  echo ">> Done. ./build.sh will now sign with \"$CERT_NAME\" automatically."
else
  echo "!! Identity \"$CERT_NAME\" is in the keychain but not valid for" >&2
  echo "!! codesigning. This usually means keyUsage or extendedKeyUsage" >&2
  echo "!! on the cert is wrong. Inspect with:" >&2
  echo "!!   security find-identity -p codesigning -v" >&2
  exit 1
fi
