#!/bin/bash
#
# Deploys a NEAR staking pool via the staking pool factory.
# 100% reward_fee_fraction, intended for a sponsored-stake program where all
# rewards route back to the pool owner.
#
# Post-deploy: run verify-pool.sh, then lock-pool.sh.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  POOL_NAME=<short-name>            \
  OWNER_ID=<account-id>             \
  STAKE_PUBLIC_KEY=ed25519:<base58> \
  DEPLOYER=<account-id>             \
  NETWORK=mainnet|testnet           \
  [DRY_RUN=1]                       \
  [SIGN_WITH=sign-with-keychain]    \
  ./deploy-pool.sh

Required env:
  POOL_NAME         Pool short name. Final contract: <POOL_NAME>.<factory>.
                    Format: 2-40 chars, lowercase a-z, 0-9, hyphens/underscores,
                    no leading or trailing hyphen.
  OWNER_ID          Account that will own the pool. Can rotate the stake key,
                    adjust fees, pause staking, vote. Typically a multisig for
                    sponsored-stake programs.
  STAKE_PUBLIC_KEY  Validator public key, format: ed25519:<base58>.
                    Must equal the public_key in /var/lib/neard/.near/validator_key.json
                    on the validator node. Mismatch = silent failure to sign.
  DEPLOYER          Signer of the deploy tx. Pays 4 NEAR storage + gas.
                    Must be importable by near-cli-rs (or adjusted via SIGN_WITH).
  NETWORK           mainnet or testnet. No default; must be set explicitly.

Optional env:
  DRY_RUN           If "1", prints the planned call and exits without sending.
  SIGN_WITH         near-cli-rs signer method. Defaults to sign-with-keychain.
                    Useful overrides:
                      sign-with-ledger
                      sign-later                  (produces unsigned tx for multisig)
                      sign-with-access-key-file
                      sign-with-legacy-keychain
  CODE_HASH         Factory code_hash for the pool wasm to deploy. Defaults to
                    the canonical pool.near staking-pool contract hash.

Factory targets:
  mainnet -> pool.near (upgradeable)
  testnet -> factory01.littlefarm.testnet

Deploy call:
  create_staking_pool({
    staking_pool_id:     POOL_NAME,
    owner_id:            OWNER_ID,
    stake_public_key:    STAKE_PUBLIC_KEY,
    reward_fee_fraction: {numerator: 1, denominator: 1},
    code_hash:           CODE_HASH
  })

Gas: 300 Tgas. Attached: 4 NEAR (factory storage deposit).
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

: "${POOL_NAME:?POOL_NAME must be set. See --help.}"
: "${OWNER_ID:?OWNER_ID must be set. See --help.}"
: "${STAKE_PUBLIC_KEY:?STAKE_PUBLIC_KEY must be set. See --help.}"
: "${DEPLOYER:?DEPLOYER must be set. See --help.}"
: "${NETWORK:?NETWORK must be set (mainnet or testnet). See --help.}"
DRY_RUN="${DRY_RUN:-0}"
SIGN_WITH="${SIGN_WITH:-sign-with-keychain}"

# POOL_NAME: NEAR account id label rules - alphanum + hyphens/underscores,
# separators only between alphanum (no adjacent separators, no leading/trailing).
if ! [[ "$POOL_NAME" =~ ^[a-z0-9]+([-_][a-z0-9]+)*$ ]] \
   || [ ${#POOL_NAME} -lt 2 ] || [ ${#POOL_NAME} -gt 40 ]; then
  echo "ERROR: POOL_NAME must be 2-40 chars, lowercase alphanum + single hyphens/underscores as separators, no leading/trailing/adjacent separators." >&2
  exit 1
fi

if ! [[ "$STAKE_PUBLIC_KEY" =~ ^ed25519:[1-9A-HJ-NP-Za-km-z]{43,44}$ ]]; then
  echo "ERROR: STAKE_PUBLIC_KEY must match ed25519:<base58> (43-44 char base58 suffix)." >&2
  exit 1
fi

case "$NETWORK" in
  mainnet)
    FACTORY="pool.near"
    NETWORK_LABEL="MAINNET (production)"
    ;;
  testnet)
    FACTORY="factory01.littlefarm.testnet"
    NETWORK_LABEL="testnet"
    ;;
  *)
    echo "ERROR: NETWORK must be 'mainnet' or 'testnet'." >&2
    exit 1
    ;;
esac

POOL_CONTRACT="${POOL_NAME}.${FACTORY}"

command -v near >/dev/null 2>&1 || {
  echo "ERROR: near-cli-rs not found on PATH." >&2
  echo "Install: curl -sSfL https://raw.githubusercontent.com/near/near-cli-rs/main/install.sh | sh" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq not found on PATH." >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl not found on PATH." >&2
  exit 1
}

case "$NETWORK" in
  mainnet) RPC_URL="https://rpc.mainnet.near.org" ;;
  testnet) RPC_URL="https://rpc.testnet.near.org" ;;
esac

echo "Checking $POOL_CONTRACT does not already exist on $NETWORK..."
RPC_PROBE=$(curl -s --max-time 15 -X POST "$RPC_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"query\",\"id\":\"1\",\"params\":{\"request_type\":\"view_account\",\"finality\":\"final\",\"account_id\":\"$POOL_CONTRACT\"}}" \
  || echo '{"rpc_error":"unreachable"}')

EXISTS=$(echo "$RPC_PROBE" | jq -r '
  if .rpc_error then "rpc_error"
  elif .error.cause.name == "UNKNOWN_ACCOUNT" or (.error.data? | tostring | contains("does not exist")) then "no"
  elif .result then "yes"
  else "unknown"
  end')

case "$EXISTS" in
  no)
    echo "OK: $POOL_CONTRACT does not exist, safe to deploy."
    ;;
  yes)
    echo "ERROR: $POOL_CONTRACT already exists on $NETWORK. Pick a different POOL_NAME." >&2
    exit 1
    ;;
  rpc_error)
    echo "ERROR: RPC probe to $RPC_URL failed (timeout or network). Check connectivity and retry." >&2
    exit 1
    ;;
  *)
    echo "ERROR: RPC probe returned unexpected response for $POOL_CONTRACT. Inspect manually:" >&2
    echo "$RPC_PROBE" >&2
    exit 1
    ;;
esac

CODE_HASH="${CODE_HASH:-AjD4YJaXgpiRdiArqnzyDi7Bkr1gJms9Z2w7Ev5esTKB}"

ARGS_JSON=$(jq -nc \
  --arg id "$POOL_NAME" \
  --arg owner "$OWNER_ID" \
  --arg pk "$STAKE_PUBLIC_KEY" \
  --arg ch "$CODE_HASH" \
  '{staking_pool_id: $id, owner_id: $owner, stake_public_key: $pk, reward_fee_fraction: {numerator: 1, denominator: 1}, code_hash: $ch}')

if [ -z "$ARGS_JSON" ] || ! echo "$ARGS_JSON" | jq . >/dev/null 2>&1; then
  echo "ERROR: Failed to build valid JSON args. jq output was empty or malformed." >&2
  exit 1
fi

cat <<EOF

  Deploy plan

  Network         $NETWORK_LABEL
  Factory         $FACTORY
  Pool contract   $POOL_CONTRACT
  Owner           $OWNER_ID
  Stake pubkey    $STAKE_PUBLIC_KEY
  Reward fee      100% (numerator=1, denominator=1)
  Code hash       $CODE_HASH
  Deployer        $DEPLOYER (pays 4 NEAR storage + gas)
  Sign method     $SIGN_WITH
  Gas             300 Tgas
  Attached        4 NEAR

  Call args:
$(echo "$ARGS_JSON" | jq . | sed 's/^/    /')

EOF

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN: not sending transaction."
  exit 0
fi

if [ "$NETWORK" = "mainnet" ]; then
  PROMPT="Type YES (all caps) to send this on MAINNET: "
  EXPECT="YES"
else
  PROMPT="Type 'yes' to send on testnet: "
  EXPECT="yes"
fi

read -r -p "$PROMPT" CONFIRM
if [ "$CONFIRM" != "$EXPECT" ]; then
  echo "Aborted."
  exit 1
fi

near contract call-function as-transaction "$FACTORY" create_staking_pool \
  json-args "$ARGS_JSON" \
  prepaid-gas '300 Tgas' \
  attached-deposit '4 NEAR' \
  sign-as "$DEPLOYER" \
  network-config "$NETWORK" \
  "$SIGN_WITH" \
  send

cat <<EOF

  Pool deployed: $POOL_CONTRACT

  Next:

    POOL_CONTRACT=$POOL_CONTRACT \\
    EXPECTED_OWNER=$OWNER_ID \\
    EXPECTED_STAKE_PUBLIC_KEY=$STAKE_PUBLIC_KEY \\
    NETWORK=$NETWORK \\
    ./verify-pool.sh

  Then:

    POOL_CONTRACT=$POOL_CONTRACT \\
    NETWORK=$NETWORK \\
    ./lock-pool.sh

EOF
