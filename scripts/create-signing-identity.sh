#!/bin/bash
# Create a local code-signing identity, once, so TCC stops forgetting the app.
#
# THE PROBLEM
# TCC keys its Accessibility and Input Monitoring grants to the app's *code
# signature*, through what codesign calls the designated requirement. Ad-hoc
# signing (`codesign -s -`) has no certificate to name, so the requirement is
# the code hash itself:
#
#     designated => cdhash H"44cfd00a8a95…"
#
# That hash changes with every rebuild, so every rebuild is a different app as
# far as macOS is concerned, and the permissions have to be granted again.
#
# THE FIX
# Sign with a certificate instead. The requirement then names the certificate,
# which does not change when the code does:
#
#     designated => identifier "dev.rymndhng.teach-touch.app"
#                   and certificate leaf = H"ebeb57f59ac8…"
#
# The certificate is self-signed and lives in its own keychain. codesign does
# not require it to be trusted — signing works fine with an untrusted local
# certificate, and nothing else on the system is asked to believe it.
#
# The keychain password below is deliberately a constant in this file. The key
# it protects can sign builds of this project on this machine and nothing else,
# so a password worth protecting would only mean an interactive prompt in the
# middle of every build.

set -euo pipefail

IDENTITY="Teach Touch Local"
KEYCHAIN="$HOME/Library/Keychains/teach-touch-signing.keychain"
PASSWORD="teach-touch"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Already set up: \"$IDENTITY\" in $KEYCHAIN"
    echo "Delete that keychain and re-run if you want a fresh certificate."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Creating keychain ${KEYCHAIN}…"
if [ ! -f "${KEYCHAIN}-db" ]; then
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
# No auto-lock: a keychain that relocks on a timer turns into a build failure
# an hour later.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

echo "Generating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" 2>/dev/null

# Legacy PBE algorithms: OpenSSL 3 defaults to AES-256-CBC with a SHA-256 MAC,
# which macOS's keychain importer cannot read — it reports the file as having
# a bad password, which is a memorable way to lose an afternoon.
openssl pkcs12 -export -out "$WORK/id.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout "pass:$PASSWORD" -name "$IDENTITY" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "Importing…"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASSWORD" -A -T /usr/bin/codesign
# Let codesign use the key without a confirmation dialog on first use.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1

echo
security find-identity -p codesigning "$KEYCHAIN" | sed -n '/Matching identities/,/identities found/p'
cat <<NOTES

Done. scripts/build-app.sh will pick this up automatically.

ONE LAST RE-GRANT. The app's identity changes once more as it moves off ad-hoc
signing, so the existing permissions are stale. Clear them and grant once more:

  tccutil reset Accessibility dev.rymndhng.teach-touch.app
  tccutil reset ListenEvent dev.rymndhng.teach-touch.app

Then rebuild, open the app, and approve both prompts. That is the last time —
rebuilds keep the grants from here on.
NOTES
