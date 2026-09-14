#!/usr/bin/env bash
# Deploys the sandbox with DeployLocal and settles one trade: Bank B sells 100 bonds to
# Bank A for EUR 10m. The README's "Run it locally" steps, as a script, so CI can run them
# against Besu. Every key is a dev key; never point this at a network that holds value.
#
#   RPC       JSON-RPC endpoint                                (default: local Anvil)
#   DEPLOYER  private key that broadcasts DeployLocal          (default: Anvil account 0)
#
# The two banks are always Anvil accounts 1 and 2, as DeployLocal hardcodes them. The
# deployer sends each a little ether first, because Besu leaves a transaction from an
# account with no ether in the pool even when gas is free.
set -euo pipefail

RPC="${RPC:-http://localhost:8545}"
DEPLOYER="${DEPLOYER:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

BANK_A=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
A_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BANK_B=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
B_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

CURRENCY=0x455552                   # "EUR"
ISIN=0x444530303041314557575730     # "DE000A1EWWW0", the issue DeployLocal mints
CASH_AMOUNT=10000000000000          # EUR 10m in tEUR's six decimals
BOND_AMOUNT=100

cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

step "Chain"
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
echo "rpc      : $RPC"
echo "chain id : $CHAIN_ID"
echo "block    : $(cast block-number --rpc-url "$RPC")"

step "Deploy: registry, both legs, settlement; onboard and fund the banks"
DEPLOY_LOG=$(forge script script/DeployLocal.s.sol:DeployLocal \
  --rpc-url "$RPC" --private-key "$DEPLOYER" --broadcast --slow 2>&1) \
  || { echo "$DEPLOY_LOG"; fail "DeployLocal did not broadcast"; }
echo "$DEPLOY_LOG" | sed -n '/== Logs ==/,/^$/p'

addr() { echo "$DEPLOY_LOG" | grep -E "^\s*$1\s.*: 0x" | awk '{print $NF}'; }
CASH=$(addr TokenizedCash)
BOND=$(addr AssetToken)
DVP=$(addr DvPSettlement)
[[ -n "$CASH" && -n "$BOND" && -n "$DVP" ]] || fail "could not read the deployed addresses"

step "Give each bank ether for gas"
for bank in "$BANK_A" "$BANK_B"; do
  cast send "$bank" --value 1ether --rpc-url "$RPC" --private-key "$DEPLOYER" > /dev/null
  echo "$bank : $(cast balance "$bank" --rpc-url "$RPC" -e | cut -d. -f1) ether"
done

step "Bank B approves $BOND_AMOUNT bonds and proposes the trade"
DEADLINE=$(( $(cast block latest -f timestamp --rpc-url "$RPC") + 86400 ))
TRADE_ID=$(cast call "$DVP" "nextTradeId()(uint256)" --rpc-url "$RPC")

cast send "$BOND" "approve(address,uint256)" "$DVP" "$BOND_AMOUNT" \
  --rpc-url "$RPC" --private-key "$B_KEY" > /dev/null
cast send "$DVP" "propose((address,address,bytes3,uint256,address,bytes12,uint256,uint64))" \
  "($BANK_A,$CASH,$CURRENCY,$CASH_AMOUNT,$BOND,$ISIN,$BOND_AMOUNT,$DEADLINE)" \
  --rpc-url "$RPC" --private-key "$B_KEY" > /dev/null
echo "trade id : $TRADE_ID"
echo "deadline : $DEADLINE"

step "Bank A hashes the terms from its own record"
HASH=$(cast keccak "$(cast abi-encode \
  "f(uint256,address,uint256,address,address,address,bytes3,uint256,address,bytes12,uint256,uint64)" \
  "$CHAIN_ID" "$DVP" "$TRADE_ID" "$BANK_B" "$BANK_A" \
  "$CASH" "$CURRENCY" "$CASH_AMOUNT" "$BOND" "$ISIN" "$BOND_AMOUNT" "$DEADLINE")")
echo "hash     : $HASH"

step "canSettle before the cash is approved"
PREVIEW=$(cast call "$DVP" "canSettle(uint256,bytes32)(bool,bytes4)" "$TRADE_ID" "$HASH" --rpc-url "$RPC")
echo "$PREVIEW"
# 0xfb8f41b2 is ERC20InsufficientAllowance: right reason, so the preview reads the legs.
[[ "$PREVIEW" == *false* && "$PREVIEW" == *0xfb8f41b2* ]] || fail "expected (false, ERC20InsufficientAllowance)"

step "Bank A approves the cash and settles"
cast send "$CASH" "approve(address,uint256)" "$DVP" "$CASH_AMOUNT" \
  --rpc-url "$RPC" --private-key "$A_KEY" > /dev/null
RECEIPT=$(cast send "$DVP" "settle(uint256,bytes32)" "$TRADE_ID" "$HASH" \
  --rpc-url "$RPC" --private-key "$A_KEY")
echo "$RECEIPT" | grep -E '^(status|transactionHash|blockNumber|gasUsed)'
[[ "$RECEIPT" == *"status               1"* ]] || fail "settle transaction did not succeed"

step "Both legs moved"
# `${x%% *}` drops the "[1e13]" annotation cast appends to large numbers.
BOND_A=$(cast call "$BOND" "balanceOf(address)(uint256)" "$BANK_A" --rpc-url "$RPC"); BOND_A=${BOND_A%% *}
CASH_B=$(cast call "$CASH" "balanceOf(address)(uint256)" "$BANK_B" --rpc-url "$RPC"); CASH_B=${CASH_B%% *}
echo "Bank A bonds : $BOND_A"
echo "Bank B cash  : $CASH_B"
[[ "$BOND_A" == "$BOND_AMOUNT" ]] || fail "Bank A holds $BOND_A bonds, expected $BOND_AMOUNT"
[[ "$CASH_B" == "$CASH_AMOUNT" ]] || fail "Bank B holds $CASH_B cash, expected $CASH_AMOUNT"

step "Settling again is refused before anything moves"
PREVIEW=$(cast call "$DVP" "canSettle(uint256,bytes32)(bool,bytes4)" "$TRADE_ID" "$HASH" --rpc-url "$RPC")
echo "$PREVIEW"
# 0xa93022f3 is TradeNotOpen: the record is SETTLED, so the hash is never even checked.
[[ "$PREVIEW" == *false* && "$PREVIEW" == *0xa93022f3* ]] || fail "expected (false, TradeNotOpen)"

printf '\nOK: trade %s settled on chain %s\n' "$TRADE_ID" "$CHAIN_ID"
