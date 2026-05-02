#!/bin/bash
#
# Post-deploy verification of a NEAR staking pool contract.
# Checks state via view-method calls and account metadata via RPC.
# Exits 0 only if every strict check passes.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  POOL_CONTRACT=<pool-account-id>                    \
  EXPECTED_OWNER=<account-id>                        \
  EXPECTED_STAKE_PUBLIC_KEY=ed25519:<base58>         \
  NETWORK=mainnet|testnet                            \
  [EXPECTED_FEE_NUMERATOR=1]                         \
  [EXPECTED_FEE_DENOMINATOR=1]                       \
  [EXPECTED_CODE_HASH=<base58>]                      \
  ./verify-pool.sh

Required env:
  POOL_CONTRACT              Full pool contract account, e.g. <pool-name>.pool.near.
  EXPECTED_OWNER             The account that should be the pool owner.
  EXPECTED_STAKE_PUBLIC_KEY  The validator pubkey that should match the pool's stake_public_key.
  NETWORK                    mainnet or testnet. No default.

Optional env:
  EXPECTED_FEE_NUMERATOR     Default 1.
  EXPECTED_FEE_DENOMINATOR   Default 1.
  EXPECTED_CODE_HASH         If unset on mainnet, derived at runtime from three
                             reference pools (liver.pool.near, svrn.pool.near,
                             marcus.pool.near). On testnet, if unset the
                             code-hash check is advisory (observed hash is
                             printed, comparison is skipped).

Strict checks (any fail -> exit 1):
  1. Account exists at POOL_CONTRACT.
  2. get_owner_id            == EXPECTED_OWNER
  3. get_staking_key         == EXPECTED_STAKE_PUBLIC_KEY
  4. get_reward_fee_fraction == {EXPECTED_FEE_NUMERATOR, EXPECTED_FEE_DENOMINATOR}
  5. is_staking_paused       == false
  6. Access key count        == 0  (pool is keyless per staking-pool invariant)
  7. Account code_hash       matches expected (on mainnet, derived from
                             reference pools; on testnet, advisory unless
                             EXPECTED_CODE_HASH set).

Informational (displayed, not compared):
  - get_total_staked_balance
  - get_number_of_accounts
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

: "${POOL_CONTRACT:?POOL_CONTRACT must be set. See --help.}"
: "${EXPECTED_OWNER:?EXPECTED_OWNER must be set. See --help.}"
: "${EXPECTED_STAKE_PUBLIC_KEY:?EXPECTED_STAKE_PUBLIC_KEY must be set. See --help.}"
: "${NETWORK:?NETWORK must be set (mainnet or testnet). See --help.}"
EXPECTED_FEE_NUMERATOR="${EXPECTED_FEE_NUMERATOR:-1}"
EXPECTED_FEE_DENOMINATOR="${EXPECTED_FEE_DENOMINATOR:-1}"

case "$NETWORK" in
  mainnet) RPC_URL="https://rpc.mainnet.near.org" ;;
  testnet) RPC_URL="https://rpc.testnet.near.org" ;;
  *) echo "ERROR: NETWORK must be 'mainnet' or 'testnet'." >&2; exit 1 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not on PATH." >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq not on PATH." >&2; exit 1; }

rpc_call() {
  curl -s --max-time 15 -X POST "$RPC_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"$1\",\"params\":$2}"
}

view_account() {
  rpc_call query "{\"request_type\":\"view_account\",\"finality\":\"final\",\"account_id\":\"$1\"}"
}

view_access_keys() {
  rpc_call query "{\"request_type\":\"view_access_key_list\",\"finality\":\"final\",\"account_id\":\"$1\"}"
}

# call_view_method <account> <method> [args_json]
# Returns the decoded ASCII/UTF-8 result from the function call.
call_view_method() {
  local account="$1" method="$2" args_json="${3:-{\}}"
  local args_b64
  # Portable base64 without line-wrapping (works on GNU coreutils and BSD/macOS).
  args_b64=$(printf '%s' "$args_json" | base64 | tr -d '\n')
  rpc_call query "{\"request_type\":\"call_function\",\"finality\":\"final\",\"account_id\":\"$account\",\"method_name\":\"$method\",\"args_base64\":\"$args_b64\"}" \
    | jq -r '.result.result | implode'
}

report() {
  local status="$1" name="$2" got="$3" expected="${4:-}"
  if [ "$status" = "PASS" ]; then
    printf '  [PASS] %-28s %s\n' "$name" "$got"
    PASS_COUNT=$((PASS_COUNT + 1))
  elif [ "$status" = "FAIL" ]; then
    printf '  [FAIL] %-28s got=%s expected=%s\n' "$name" "$got" "$expected"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    printf '  [INFO] %-28s %s\n' "$name" "$got"
  fi
}

PASS_COUNT=0
FAIL_COUNT=0

echo
echo "  Verifying $POOL_CONTRACT on $NETWORK"
echo

ACCOUNT_RESP=$(view_account "$POOL_CONTRACT")
if echo "$ACCOUNT_RESP" | jq -e '.error' >/dev/null; then
  report FAIL "account exists" "does not exist" "account present"
  echo
  echo "Account $POOL_CONTRACT does not exist on $NETWORK. Other checks skipped."
  exit 1
fi
report PASS "account exists" "yes"

CODE_HASH=$(echo "$ACCOUNT_RESP" | jq -r '.result.code_hash')
AMOUNT=$(echo "$ACCOUNT_RESP" | jq -r '.result.amount')
STORAGE_USAGE=$(echo "$ACCOUNT_RESP" | jq -r '.result.storage_usage')

OWNER=$(call_view_method "$POOL_CONTRACT" get_owner_id | tr -d '"')
if [ "$OWNER" = "$EXPECTED_OWNER" ]; then
  report PASS "get_owner_id" "$OWNER"
else
  report FAIL "get_owner_id" "$OWNER" "$EXPECTED_OWNER"
fi

STAKE_KEY=$(call_view_method "$POOL_CONTRACT" get_staking_key | tr -d '"')
if [ "$STAKE_KEY" = "$EXPECTED_STAKE_PUBLIC_KEY" ]; then
  report PASS "get_staking_key" "$STAKE_KEY"
else
  report FAIL "get_staking_key" "$STAKE_KEY" "$EXPECTED_STAKE_PUBLIC_KEY"
fi

FEE_JSON=$(call_view_method "$POOL_CONTRACT" get_reward_fee_fraction)
FEE_NUM=$(echo "$FEE_JSON" | jq -r '.numerator')
FEE_DEN=$(echo "$FEE_JSON" | jq -r '.denominator')
if [ "$FEE_NUM" = "$EXPECTED_FEE_NUMERATOR" ] && [ "$FEE_DEN" = "$EXPECTED_FEE_DENOMINATOR" ]; then
  report PASS "get_reward_fee_fraction" "${FEE_NUM}/${FEE_DEN}"
else
  report FAIL "get_reward_fee_fraction" "${FEE_NUM}/${FEE_DEN}" "${EXPECTED_FEE_NUMERATOR}/${EXPECTED_FEE_DENOMINATOR}"
fi

PAUSED=$(call_view_method "$POOL_CONTRACT" is_staking_paused)
if [ "$PAUSED" = "false" ]; then
  report PASS "is_staking_paused" "false"
else
  report FAIL "is_staking_paused" "$PAUSED" "false"
fi

KEY_RESP=$(view_access_keys "$POOL_CONTRACT")
KEY_COUNT=$(echo "$KEY_RESP" | jq -r '.result.keys | length')
if [ "$KEY_COUNT" = "0" ]; then
  report PASS "access_key_count" "0 (keyless)"
else
  report FAIL "access_key_count" "$KEY_COUNT" "0"
  echo "  Keys present on $POOL_CONTRACT:"
  echo "$KEY_RESP" | jq -r '.result.keys[] | "    - \(.public_key)  \(.access_key.permission)"'
fi

if [ -n "${EXPECTED_CODE_HASH:-}" ]; then
  if [ "$CODE_HASH" = "$EXPECTED_CODE_HASH" ]; then
    report PASS "code_hash (user-provided)" "$CODE_HASH"
  else
    report FAIL "code_hash (user-provided)" "$CODE_HASH" "$EXPECTED_CODE_HASH"
  fi
elif [ "$NETWORK" = "mainnet" ]; then
  REF_POOLS="liver.pool.near svrn.pool.near marcus.pool.near"
  REF_HASHES=""
  REF_FAIL=0
  for ref in $REF_POOLS; do
    h=$(view_account "$ref" | jq -r '.result.code_hash // empty')
    if [ -z "$h" ]; then
      echo "  warning: reference pool $ref unreachable"
      REF_FAIL=1
    else
      REF_HASHES="$REF_HASHES$h"$'\n'
    fi
  done
  UNIQ_HASHES=$(printf '%s' "$REF_HASHES" | grep -v '^$' | sort -u)
  REF_COUNT=$(printf '%s\n' "$UNIQ_HASHES" | grep -c . || true)
  if [ "$REF_FAIL" = "1" ]; then
    report FAIL "code_hash attestation" "reference pool(s) unreachable" "all 3 references reachable"
  elif [ "$REF_COUNT" = "1" ] && [ -n "$UNIQ_HASHES" ]; then
    EXPECTED_DERIVED="$UNIQ_HASHES"
    if [ "$CODE_HASH" = "$EXPECTED_DERIVED" ]; then
      report PASS "code_hash (derived)" "$CODE_HASH"
    else
      report FAIL "code_hash (derived)" "$CODE_HASH" "$EXPECTED_DERIVED"
      echo "  Reference pools used: $REF_POOLS"
    fi
  else
    report FAIL "code_hash attestation" "reference pools disagree" "all 3 to match"
    echo "  Distinct hashes observed:"
    echo "$UNIQ_HASHES" | sed 's/^/    /'
    echo "  Investigate factory state or set EXPECTED_CODE_HASH manually."
  fi
else
  report INFO "code_hash (testnet, advisory)" "$CODE_HASH"
  echo "  Set EXPECTED_CODE_HASH env to enable strict comparison on testnet."
fi

echo
TOTAL_STAKED=$(call_view_method "$POOL_CONTRACT" get_total_staked_balance | tr -d '"')
report INFO "get_total_staked_balance" "$TOTAL_STAKED yoctoNEAR"

NUM_ACCOUNTS=$(call_view_method "$POOL_CONTRACT" get_number_of_accounts)
report INFO "get_number_of_accounts" "$NUM_ACCOUNTS"

report INFO "account balance" "$AMOUNT yoctoNEAR"
report INFO "storage_usage" "$STORAGE_USAGE bytes"

echo
printf "  Result: %d passed, %d failed\n" "$PASS_COUNT" "$FAIL_COUNT"
echo

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
