#!/bin/sh
# Create a self-signed code-signing identity so every PairDesk build from this
# Mac is signed the same way. Run it once on the Mac that builds PairDesk;
# scripts/build-app.sh then uses the identity automatically.
#
# Why: an ad-hoc build's designated requirement is its cdhash, so macOS treats
# each new build as a different app. The saved sign-in in the login keychain
# then asks for the Mac password twice per install (the item's ACL, then its
# partition list), and Accessibility or microphone approval can reset. Signed
# with this identity, the requirement is
#   identifier "app.internal.pairdesk" and certificate leaf = H"..."
# which every build shares, so "Always Allow" lasts across updates.
#
# Builds for teammates must always come from the same identity. To build on
# another Mac, export it from Keychain Access and keep the export private:
# anyone holding it can sign an app the keychain trusts as PairDesk. This does
# not replace Developer ID signing and notarization for Gatekeeper.
set -eu

NAME=${PAIRDESK_SIGNING_NAME:-PairDesk Local Signing}
KEYCHAIN=${PAIRDESK_SIGNING_KEYCHAIN:-"$HOME/Library/Keychains/login.keychain-db"}

if security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\"" >/dev/null; then
  echo "Signing identity \"$NAME\" already exists in $KEYCHAIN."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# Use macOS's LibreSSL: `security import` rejects the PKCS#12 encryption that
# OpenSSL 3 and later use by default.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
TRANSFER_PASSWORD=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout "pass:$TRANSFER_PASSWORD" -out "$WORK/identity.p12"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$TRANSFER_PASSWORD" -T /usr/bin/codesign >/dev/null

# Let codesign use only this key without a dialog. Without this step, the
# first build shows "codesign wants to sign using key"; choose Always Allow.
echo "Allowing codesign to use the new key. Enter the keychain password (usually your Mac login password)."
if [ -n "${PAIRDESK_SIGNING_KEYCHAIN_PASSWORD:-}" ]; then
  set -- -k "$PAIRDESK_SIGNING_KEYCHAIN_PASSWORD"
else
  set --
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$NAME" "$@" "$KEYCHAIN" >/dev/null ||
  echo "Skipped; the first build will ask once. Choose Always Allow."

echo "Created \"$NAME\" in $KEYCHAIN."
echo "scripts/build-app.sh now signs with it. Expect one last keychain prompt on the first launch of the"
echo "new build (the saved sign-in still trusts the old ad-hoc build); choose Always Allow."
