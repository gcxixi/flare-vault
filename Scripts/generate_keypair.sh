#!/usr/bin/env bash
#
# Helper script to generate RSA keypairs for FlareVault.
#

set -euo pipefail

BITS="${1:-2048}"
OUT_DIR="${2:-.}"

mkdir -p "$OUT_DIR"

PRIV_KEY="$OUT_DIR/flarevault_private_key.pem"
PUB_KEY="$OUT_DIR/flarevault_public_key.pem"

echo "=== FlareVault Key Generator ==="
echo "Generating $BITS-bit RSA keypair..."

# Prompt for optional passphrase
echo -n "Enter passphrase to protect private key (or press Enter for no password): "
read -s PASSPHRASE
echo ""

if [ -n "$PASSPHRASE" ]; then
    openssl genrsa -aes256 -passout "pass:$PASSPHRASE" -out "$PRIV_KEY" "$BITS" 2>/dev/null
    openssl rsa -in "$PRIV_KEY" -passin "pass:$PASSPHRASE" -pubout -out "$PUB_KEY" 2>/dev/null
else
    openssl genrsa -out "$PRIV_KEY" "$BITS" 2>/dev/null
    openssl rsa -in "$PRIV_KEY" -pubout -out "$PUB_KEY" 2>/dev/null
fi

chmod 600 "$PRIV_KEY"
chmod 644 "$PUB_KEY"

echo "---------------------------------------------------------"
echo "Private Key (KEEP SAFE & OFFLINE): $PRIV_KEY"
echo "Public Key (IMPORT INTO FLAREVAULT APP): $PUB_KEY"
echo "---------------------------------------------------------"
echo "Public Key Fingerprint (SHA256):"
openssl rsa -pubin -in "$PUB_KEY" -outform DER 2>/dev/null | openssl dgst -sha256
echo "========================================================="
