#!/bin/bash
# Creates a stable self-signed code-signing identity ("Availeth Self-Signed") in
# the login keychain, so macOS TCC permission grants (Accessibility, Screen
# Recording, Input Monitoring) persist across rebuilds.
#
# Why this is needed: an ad-hoc signature (`codesign --sign -`) has no stable
# code identity — its cdhash changes every build, and TCC keys grants to that
# hash, so every rebuild silently invalidates the user's permission grants. A
# self-signed cert gives a fixed designated requirement (cert leaf + bundle id),
# so grants stick as long as we sign with the same cert.
#
# Run once. Idempotent-ish: re-running creates another cert; delete old ones in
# Keychain Access if you re-run. For real distribution, use a Developer ID cert
# and notarization instead.
set -euo pipefail

NAME="Availeth Self-Signed"
OSSL="$(command -v /opt/homebrew/bin/openssl || command -v openssl)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/availeth.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = Availeth Self-Signed
[ v3 ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

echo "Generating key + self-signed code-signing cert…"
"$OSSL" req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/availeth.cnf" -extensions v3 >/dev/null 2>&1

# Legacy PKCS12 algorithms so Apple's `security` tool can import it.
"$OSSL" pkcs12 -export -out "$TMP/availeth.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:availeth -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES >/dev/null 2>&1

echo "Importing into login keychain…"
security import "$TMP/availeth.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P availeth -A

echo "Trusting the cert for code signing…"
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem" || true

echo "Done. Identity:"
security find-identity -v -p codesigning | grep "$NAME" || {
  echo "ERROR: identity not found after import" >&2; exit 1; }
