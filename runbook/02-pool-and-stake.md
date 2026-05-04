# 02 - Pool deploy and stake

After [01-deploy.md](01-deploy.md) the node is synced but unstaked. This step binds the validator key to a deployed staking pool and gets the validator into the next epoch's set.

The pool is deployed by **whoever holds the deployer NEAR account** with funds for the 4 NEAR pool-creation deposit (typically the HoS / NF team's signing operator, not the validator-node operator).

## Inputs

- Validator pubkey from `/var/lib/near-city-nodes/validator_pubkey.txt` (handed off in step 10 of [01-deploy.md](01-deploy.md)).
- Pool name. Becomes `<name>.pool.near` on mainnet via the `pool.near` factory. Pick a short kebab-case identifier per cohort.
- Pool owner account (e.g. HoS multisig). The owner controls future `update_staking_key`, `pause_staking`, etc.
- Funded deployer account with at least 5 NEAR.

## Pre-deploy hard gate

Run these read-only checks from the deployer's signing lane immediately before the deploy. Catches `pool.near` factory upgrades that would break the script's assumptions.

```bash
# 1. Confirm pool.near min deposit unchanged
near contract call-function as-read-only pool.near get_min_attached_balance \
    json-args '{}' network-config mainnet now
# Expect: "4000000000000000000000000". STOP if different - the script attaches 4 NEAR.

# 2. Confirm pool.near is still shipping the wasm verify-pool.sh expects.
# Pick any recent pool deploy via pool.near (last 30 days) - browse
# https://nearblocks.io/address/pool.near?tab=txns for a recent
# create_staking_pool tx and grab the resulting <name>.pool.near, then:
curl -s -X POST https://rpc.mainnet.near.org -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"query","params":{"request_type":"view_account","finality":"final","account_id":"<recent-pool>.pool.near"}}' \
  | jq -r '.result.code_hash'
# Expect: AjD4YJaXgpiRdiArqnzyDi7Bkr1gJms9Z2w7Ev5esTKB
# (matches verify-pool.sh's reference set: liver/svrn/marcus.pool.near).
# If different, pool.near has shipped a new wasm and the script's code_hash
# attestation will need EXPECTED_CODE_HASH=<new-hash> set explicitly.
```

Both checks are read-only, free, and take under 30 seconds.

## Pool deploy

Run `scripts/deploy-pool.sh` from the deployer's workstation (NOT the validator box):

```bash
POOL_NAME=<your-pool-name> \
OWNER_ID=<hos-multisig.near> \
STAKE_PUBLIC_KEY=ed25519:<validator-pubkey> \
DEPLOYER=<your-near-account.near> \
NETWORK=mainnet \
./scripts/deploy-pool.sh
```

The script does a dry-run first. Confirm the parameters then re-run with `--apply`. Verify with:

```bash
POOL_CONTRACT=<your-pool>.pool.near \
EXPECTED_OWNER=<hos-multisig.near> \
EXPECTED_STAKE_PUBLIC_KEY=ed25519:<validator-pubkey> \
NETWORK=mainnet \
./scripts/verify-pool.sh
```

## Bind the node to the pool

Once the pool exists on-chain, edit `/etc/near-city-nodes/node.env` on the validator box:

```bash
ssh root@<NODE_PUBLIC_IP> '
  sed -i "s/^POOL_ACCOUNT=.*/POOL_ACCOUNT=<your-pool>.pool.near/" /etc/near-city-nodes/node.env
  cd /opt/near-city-nodes &&
  ./bootstrap.sh --phase 06-neard-init --force &&
  ./bootstrap.sh --phase 08-monitoring --force
'
```

This rewrites `validator_key.json`'s `account_id` (without regenerating the keypair) and the prometheus `pool` label. Then restart neard at the next epoch-safe window:

```bash
ssh root@<NODE_PUBLIC_IP> '
  curl -s http://localhost:3030/status | jq -r ".sync_info | (\"epoch=\" + ((.latest_block_height - .epoch_start_height) | tostring))"
  # If under 75% of 43200 blocks into the epoch, restart now:
  systemctl restart neard-mainnet
'
```

## Funding + staking

The pool owner deposits NEAR into the pool and calls `deposit_and_stake`. Stake amount must clear the current chunk-validator seat threshold (~9,800 NEAR as of 2026-04, check live:

```bash
curl -s -X POST https://rpc.mainnet.near.org -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"validators","params":[null]}' \
  | jq '.result | {seat_threshold_near: ([.current_validators[].stake | tonumber] | min / 1e24 | floor)}'
```

## Wait for inclusion

The validator enters the active set over ~2 epochs (~26-40 h):
- Epoch N: stake action seen -> appears in `current_proposals`.
- Epoch N+1: appears in `next_validators`.
- Epoch N+2: appears in `current_validators` and starts producing chunks.

Watch with:

```bash
curl -s -X POST https://rpc.mainnet.near.org -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"validators","params":[null]}' \
  | jq --arg pool "<your-pool>.pool.near" '
    {
      epoch_height: .result.epoch_height,
      we_in_proposals: ([.result.current_proposals[] | select(.account_id == $pool)]),
      we_in_next: ([.result.next_validators[] | select(.account_id == $pool)]),
      we_in_current: ([.result.current_validators[] | select(.account_id == $pool)])
    }'
```

## Lock the pool (optional, recommended)

After the pool is verified and staking, lock the pool to enforce the keyless invariant (no full-access keys remain on the pool account):

```bash
POOL_CONTRACT=<your-pool>.pool.near NETWORK=mainnet \
SIGN_WITH=<hos-multisig.near> \
./scripts/lock-pool.sh
```
