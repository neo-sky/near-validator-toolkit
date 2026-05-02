# 99 - Recovery

Things go wrong. Here's how to put them right without making them worse.

## List phase state

```bash
./bootstrap.sh --list
```

Shows each phase + `pending`/`done`. Markers live at `/var/lib/near-city-nodes/bootstrap-state/<phase>.done`.

## Re-run a single phase

```bash
./bootstrap.sh --phase 09-alerting --force
```

`--force` deletes the marker before running. Without `--force`, a phase with an existing marker short-circuits.

## Re-run from a given phase forward

```bash
./bootstrap.sh --from 08-monitoring --force
```

## Validator key restore

The validator key (`/var/lib/neard/.near/validator_key.json`) is the on-chain identity of this validator. Loss is recoverable but expensive - the pool owner must call `update_staking_key` on the pool to point at a new key.

**Backup**: after first deploy, copy `validator_key.json` and `node_key.json` to operator's secrets vault:

```bash
ssh root@<NODE_PUBLIC_IP> 'cat /var/lib/neard/.near/validator_key.json' > validator_key.json.backup
ssh root@<NODE_PUBLIC_IP> 'cat /var/lib/neard/.near/node_key.json' > node_key.json.backup
# Encrypt with age and store in vault. Delete plaintext.
```

**Restore** to a rebuilt host:

```bash
# After phase 04 completes (docker installed) but before phase 06 (init):
scp validator_key.json.backup root@<NODE_PUBLIC_IP>:/var/lib/neard/.near/validator_key.json
scp node_key.json.backup root@<NODE_PUBLIC_IP>:/var/lib/neard/.near/node_key.json
ssh root@<NODE_PUBLIC_IP> 'chown neard:neard /var/lib/neard/.near/{validator,node}_key.json && chmod 600 /var/lib/neard/.near/validator_key.json'
./bootstrap.sh --from 06-neard-init
```

Phase 06 detects existing keys and skips regeneration; only re-applies `public_addrs` and `account_id`.

## Lost validator key (no backup)

1. Stop the node: `sudo systemctl stop neard-mainnet`.
2. Re-run `./bootstrap.sh --phase 06-neard-init --force` after deleting `/var/lib/neard/.near/{validator,node}_key.json`. This generates a fresh keypair.
3. Get the new validator pubkey: `cat /var/lib/near-city-nodes/validator_pubkey.txt`.
4. The pool owner calls `update_staking_key` on the pool with the new pubkey.
5. Restart neard: `sudo systemctl start neard-mainnet`. The next epoch's chunk-validator selection uses the new key.

Expected downtime: ~2-3 epochs (~26-40 h) - same window as a fresh stake.

## Full host rebuild (`/var/lib/neard` lost or corrupt)

If only `/var/lib/neard` is gone but the box is otherwise healthy:

1. Restore `validator_key.json` and `node_key.json` from vault into `/var/lib/neard/.near/` (see above).
2. Re-run `./bootstrap.sh --from 06-neard-init` - phase 06 re-downloads genesis and config; phases 07-11 re-install systemd and monitoring (no-op if already done).

Expected wall time: ~30-50 min (mostly genesis download + state sync from peers).

If the box itself is gone:

1. Order replacement Hetzner with same specs.
2. Run [01-deploy.md](01-deploy.md) end-to-end.
3. After phase 05 (image built) but before phase 06 (init), restore key files as above.
4. Continue with `./bootstrap.sh --from 06-neard-init`.

## Bootstrap log forensic

```bash
tail -100 /var/log/near-city-nodes/bootstrap.log
```

Each phase prefixes its log lines with the phase name. To filter:

```bash
grep '\[06-neard-init\]' /var/log/near-city-nodes/bootstrap.log
```

## Reset bootstrap state (start over without rebuilding)

```bash
sudo rm -rf /var/lib/near-city-nodes/bootstrap-state/
./bootstrap.sh
```

Phases are idempotent so re-running on a healthy node is safe; phase 05 (docker build) will skip if `nearcore:<NEARCORE_TAG>` exists, phase 06 will skip if keys exist, etc. Re-running this way is the cleanest way to verify the deployed state matches the repo's intent.
