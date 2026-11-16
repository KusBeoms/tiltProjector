#!/bin/bash
# Creates a self-signed code-signing identity ("TiltProjector Local Signing") in its own keychain, once.
#
# Why: the Screen Recording permission is tied to the app's
# signature. Ad-hoc signatures change with every build, so the permission would be lost on each reinstall.
# Signed with this certificate the identity stays the same, so it only has to be granted once.
#
# Nothing here touches your login keychain. The private key lives only in
# ~/Library/Keychains/tiltprojector-signing.keychain-db (empty password; it is a local, self-signed key).
set -euo pipefail

NAME="TiltProjector Local Signing"
KC="$HOME/Library/Keychains/tiltprojector-signing.keychain-db"

if [ -e "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
    echo "already set up: $NAME ($KC)"; exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT     # key material only ever exists in this temp dir
cd "$WORK"

cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = TiltProjector Local Signing
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
# 3DES/SHA1 packaging: the only p12 flavour macOS' `security import` reads from newer OpenSSL builds
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -name "$NAME" -passout pass:tp \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

[ -e "$KC" ] && security delete-keychain "$KC"
security create-keychain -p "" "$KC"
security set-keychain-settings "$KC"                 # never auto-lock
security unlock-keychain -p "" "$KC"
security import id.p12 -k "$KC" -P tp -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KC" >/dev/null   # codesign may use the key without a prompt

echo "created '$NAME' in $KC"
security find-identity -p codesigning "$KC"
