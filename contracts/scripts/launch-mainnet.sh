#!/usr/bin/env bash
# Deploys the capped Plumb vault on Mezo mainnet, records it, verifies the source, and
# optionally makes the first deposit. Stops before sending anything if the wallet can't pay.
#
# Env:
#   PRIVATE_KEY     deployer key (also the treasury that receives the 10% MEZO fee)
#   DEPOSIT_CAP     raw mUSDC (6 decimals); default 5000000000 = 5,000 mUSDC
#   FIRST_DEPOSIT   raw mUSDC to deposit after deploying; default 0 (none)
#   MEZO_RPC_URL    default https://mezo.drpc.org
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=${MEZO_RPC_URL:-https://mezo.drpc.org}
CAP=${DEPOSIT_CAP:-5000000000}
FIRST=${FIRST_DEPOSIT:-0}
MUSDC=0x04671C72Aab5AC02A03c1098314b1BB6B560c197
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")

[ "$(cast chain-id --rpc-url "$RPC")" = "31612" ] || { echo "not Mezo mainnet" >&2; exit 1; }
btc=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
if [ "$(python3 -c "print(int($btc) >= 10**14)")" != "True" ]; then
  echo "deployer $DEPLOYER holds $btc wei of BTC; needs at least 0.0001 BTC for gas" >&2; exit 1
fi
if [ "$FIRST" != "0" ]; then
  usd=$(cast call "$MUSDC" "balanceOf(address)(uint256)" "$DEPLOYER" --rpc-url "$RPC" | awk '{print $1}')
  [ "$(python3 -c "print($usd >= $FIRST)")" = "True" ] || { echo "deployer holds $usd raw mUSDC, less than FIRST_DEPOSIT=$FIRST" >&2; exit 1; }
fi

echo "deploying from $DEPLOYER, cap $CAP raw mUSDC"
DEPOSIT_CAP=$CAP forge script script/DeployMainnet.s.sol --rpc-url "$RPC" --broadcast --slow

VAULT=$(python3 -c "
import json;d=json.load(open('broadcast/DeployMainnet.s.sol/31612/run-latest.json'))
print([t for t in d['transactions'] if t['transactionType']=='CREATE'][0]['contractAddress'])")
TX=$(python3 -c "
import json;d=json.load(open('broadcast/DeployMainnet.s.sol/31612/run-latest.json'))
print([t for t in d['transactions'] if t['transactionType']=='CREATE'][0]['hash'])")
[ "$(cast codesize "$VAULT" --rpc-url "$RPC")" -gt 0 ] || { echo "no code at $VAULT" >&2; exit 1; }

cat > deployments/mezo-mainnet.json <<JSON
{
  "chainId": 31612,
  "vault": "$VAULT",
  "deployTx": "$TX",
  "pool": "0xCC372B7E15535aB225fe17c1075831D38ef7aC1a",
  "gauge": "0x6d446E27505c71EE39D632488cE849fEF6aFFc57",
  "depositCap": "$CAP",
  "deployer": "$DEPLOYER"
}
JSON
printf '{ "vault": "%s" }\n' "$VAULT" > ../app/src/lib/mainnet-vault.json
echo "recorded vault $VAULT (tx $TX); app now points at it"

forge verify-contract "$VAULT" src/PlumbBidVault.sol:PlumbBidVault --chain-id 31612 \
  --verifier blockscout --verifier-url https://api.explorer.mezo.org/api/ --guess-constructor-args --rpc-url "$RPC" \
  || echo "verification submit failed; retry with the same command" >&2

if [ "$FIRST" != "0" ]; then
  cast send "$MUSDC" "approve(address,uint256)" "$VAULT" "$FIRST" --private-key "$PRIVATE_KEY" --rpc-url "$RPC" >/dev/null
  cast send "$VAULT" "depositAndDeploy(uint256,uint256,address)" "$FIRST" 0 "$DEPLOYER" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC" | grep -E "^status|^transactionHash"
  cast call "$VAULT" "band()(uint256,bool)" --rpc-url "$RPC"
  cast call "$VAULT" "bid()(uint256,bool)" --rpc-url "$RPC"
  cast call "$VAULT" "totalAssets()(uint256)" --rpc-url "$RPC"
fi
