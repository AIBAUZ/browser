#!/usr/bin/env bash
set -euo pipefail

# One-time helper for updater manifest signing keys.
# Usage:
#   ./scripts/updater/generate_signing_keypair.sh security/updater-signing
#
# Produces:
#   <prefix>-private.pem  (DO NOT COMMIT)
#   <prefix>-public.pem   (commit or embed in browser source)

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <output-prefix>"
  exit 1
fi

PREFIX="$1"
PRIVATE_KEY="${PREFIX}-private.pem"
PUBLIC_KEY="${PREFIX}-public.pem"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "${PRIVATE_KEY}"
openssl pkey -in "${PRIVATE_KEY}" -pubout -out "${PUBLIC_KEY}"

chmod 600 "${PRIVATE_KEY}"

echo "Generated:"
echo "  Private key: ${PRIVATE_KEY}"
echo "  Public key : ${PUBLIC_KEY}"
echo ""
echo "Next:"
echo "1) Put private key PEM into GitHub Actions secret: UPDATER_SIGNING_PRIVATE_KEY_PEM"
echo "2) Embed/pin public key in browser updater code."

