#!/bin/bash
#
# Enforces the staking-pool keyless invariant on a deployed pool contract.
#
# The staking-pool invariant (README lines 19-20 of the canonical contract):
#   "For secure operation of the staking pool, the contract should not have
#    any access keys. Otherwise the contract account may issue a transaction
#    that can violate the contract guarantees."
#
# The pool.near factory produces keyless pools by default. This script
# verifies that and, if any access keys are present, provides a gated
# procedure for deleting them.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  POOL_CONTRACT=<pool-account-id>    \
  NETWORK=mainnet|testnet            \
  [SIGN_WITH=sign-with-keychain]     \
  ./lock-pool.sh

Required env:
  POOL_CONTRACT   Full pool contract account, e.g. <pool-name>.pool.near.
  NETWORK         mainnet or testnet. No default.

Optional env:
  SIGN_WITH       near-cli-rs signer method used for the delete-keys tx.
                  Default sign-with-keychain. Only consulted if keys exist.

Behavior:
  - If the pool account has zero access keys (expected case for a pool
    deployed via pool.near or poolv1.near factory), prints OK and exits 0.
  - If any access keys exist, lists them, warns, requires typed
    confirmation, then issues a single near-cli-rs `delete-keys`
    transaction that removes all of them atomically. Signed as
    POOL_CONTRACT using SIGN_WITH. The user must have the corresponding
    private key imported into their near-cli-rs keychain for POOL_CONTRACT.
  - Re-verifies zero keys after deletion. Exits 1 if any remain.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

: "${POOL_CONTRACT:?POOL_CONTRACT must be set. See --help.}"
: "${NETWORK:?NETWORK must be set (mainnet or testnet). See --help.}"
SIGN_WITH="${SIGN_WITH:-sign-with-keychain}"

case "$NETWORK" in
  mainnet) RPC_URL="https://rpc.mainnet.near.org" ;;
  testnet) RPC_URL="https://rpc.testnet.near.org" ;;
  *) echo "ERROR: NETWORK must be 'mainnet' or 'testnet'." >&2; exit 1 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not on PATH." >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq not on PATH." >&2; exit 1; }

view_access_keys() {
  curl -s --max-time 15 -X POST "$RPC_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"query\",\"params\":{\"request_type\":\"view_access_key_list\",\"finality\":\"final\",\"account_id\":\"$1\"}}"
}

echo
echo "  Checking access keys on $POOL_CONTRACT ($NETWORK)"
echo

KEY_RESP=$(view_access_keys "$POOL_CONTRACT")

if echo "$KEY_RESP" | jq -e '.error' >/dev/null; then
  echo "ERROR: RPC query failed for $POOL_CONTRACT. Response:" >&2
  echo "$KEY_RESP" >&2
  exit 1
fi

KEY_COUNT=$(echo "$KEY_RESP" | jq -r '.result.keys | length')

if [ "$KEY_COUNT" = "0" ]; then
  echo "  OK: $POOL_CONTRACT is keyless. No action needed."
  echo
  exit 0
fi

echo "  WARNING: $POOL_CONTRACT has $KEY_COUNT access key(s)."
echo "  The staking-pool security invariant requires the pool account to be keyless."
echo
echo "  Keys found:"
echo "$KEY_RESP" | jq -r '.result.keys[] | "    - \(.public_key)  permission=\(.access_key.permission | if type == "object" then (keys|.[0]) else . end)"'
echo

command -v near >/dev/null 2>&1 || {
  echo "ERROR: near-cli-rs not on PATH; required to delete keys." >&2
  echo "Install: curl -sSfL https://raw.githubusercontent.com/near/near-cli-rs/main/install.sh | sh" >&2
  exit 1
}

if [ "$NETWORK" = "mainnet" ]; then
  PROMPT="  Type YES (all caps) to delete all ${KEY_COUNT} key(s) on MAINNET: "
  EXPECT="YES"
else
  PROMPT="  Type 'yes' to delete all ${KEY_COUNT} key(s) on testnet: "
  EXPECT="yes"
fi

read -r -p "$PROMPT" CONFIRM
if [ "$CONFIRM" != "$EXPECT" ]; then
  echo "  Aborted, no changes made."
  exit 1
fi

# Atomic removal avoids the "delete the signer key mid-loop" failure mode.
# NEAR applies all actions in a tx after authentication, so the signing key
# being deleted by its own tx is safe - authentication succeeded before the
# DeleteKey actions execute.
PUBKEY_CSV=$(echo "$KEY_RESP" | jq -r '.result.keys | map(.public_key) | join(",")')
echo
echo "  Deleting $KEY_COUNT key(s) in one transaction..."
if ! near account delete-keys "$POOL_CONTRACT" \
       public-keys "$PUBKEY_CSV" \
       network-config "$NETWORK" \
       "$SIGN_WITH" \
       send; then
  echo "  FAILED: near account delete-keys returned non-zero." >&2
  exit 1
fi
echo "  OK"
echo

echo "  Re-verifying key count..."
FINAL_RESP=$(view_access_keys "$POOL_CONTRACT")
FINAL_COUNT=$(echo "$FINAL_RESP" | jq -r '.result.keys | length')

if [ "$FINAL_COUNT" = "0" ]; then
  echo "  OK: $POOL_CONTRACT is now keyless."
  echo
  exit 0
fi

echo "  FAIL: $FINAL_COUNT key(s) still present on $POOL_CONTRACT after deletion attempt." >&2
echo "  Remaining keys:" >&2
echo "$FINAL_RESP" | jq -r '.result.keys[].public_key' >&2
echo >&2
exit 1
