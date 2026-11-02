#!/bin/sh
# Creates "Dial Local Signing", a self-signed code-signing identity in the
# login keychain, unless it exists. `make macos` signs with it when it
# exists: the designated requirement is then the bundle id and this
# certificate, not one build's hash, so the Accessibility and Microphone
# grants survive rebuilds. It isn't trusted and needn't be; codesign is
# allowed to use the key without asking.
set -eu

name="Dial Local Signing"
if security find-identity -p codesigning | grep -q "\"$name\""; then
    echo "$name: already in the keychain"
    exit 0
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
pass=$(openssl rand -hex 16)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
# -legacy: `security import` can't read OpenSSL 3's default encryption.
openssl pkcs12 -export -legacy -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -out "$dir/identity.p12" -passout "pass:$pass"
security import "$dir/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$pass" -T /usr/bin/codesign
echo "$name: created"
