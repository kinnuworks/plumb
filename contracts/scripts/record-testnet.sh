#!/usr/bin/env bash
# Writes deployments/mezo-testnet.json, but only for addresses that have code on chain.
set -euo pipefail
RPC=${MEZO_TESTNET_RPC_URL:-https://rpc.test.mezo.org}
POOL=$1
VAULT=$2
for a in "$POOL" "$VAULT"; do
  size=$(cast codesize "$a" --rpc-url "$RPC")
  if [ "$size" -eq 0 ]; then echo "no code at $a, not recording" >&2; exit 1; fi
done
cat > "$(dirname "$0")/../deployments/mezo-testnet.json" <<JSON
{
  "chainId": 31611,
  "pool": "$POOL",
  "vault": "$VAULT",
  "nfpm": "0x9B753e11bFEd0D88F6e1D2777E3c7dac42F96062",
  "musd": "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503",
  "usd": "0xe1a26db653708A2AD8F824E92Db9852410e33A59",
  "deployer": "$(cast wallet address --private-key "$PRIVATE_KEY")"
}
JSON
echo "recorded"
