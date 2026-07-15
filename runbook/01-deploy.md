# 01 - Deploy a validator node

End-to-end deploy of a new node from a fresh Hetzner box to a synced (but unstaked) validator. In `build` mode wall time is ~30-40 min, dominated by the nearcore compile (~15-20 min); in `pull` mode the image is fetched in seconds and the genesis download (~3 GB / 3-5 min) dominates instead. This walkthrough is the manual `build`-mode deploy on bare metal; for `pull`-mode hosts, `scripts/deploy-cloud-node.sh` runs the same sequence in one command.

## Operator prep (before the deploy window)

1. Generate ed25519 SSH keypair on the operator's workstation:
   ```bash
   ssh-keygen -t ed25519 -C "<operator>-<node>"
   ```
2. Create a Telegram bot via [@BotFather](https://t.me/BotFather). Capture the bot token.
3. Create a Telegram group/channel for alerts, add the bot, send `/start@<botname>` once. Get the chat_id from:
   ```
   https://api.telegram.org/bot<TOKEN>/getUpdates
   ```
4. Send the operator's SSH **public** key to the deployer out-of-band (Signal preferred). Send the bot token + chat_id to the deployer the same way.

## Deployer steps

### 1. Order Hetzner

Order an AX41-NVMe (or equivalent >=64 GB RAM, 2x NVMe RAID1) with **Ubuntu 22.04, 24.04, or 26.04 LTS**. The 64 GB bar is a `build`-mode requirement for compiling neard; a `pull`-mode host only needs the runtime footprint (see the gates in `bootstrap/phases/00-preflight.sh`). Hetzner's installimage handles RAID1; pick the default. Note the public IPv4 address and the `root` SSH key.

### 2. Prepare `node.env` locally

```bash
cp .env.example node.env
# Fill in: OPERATOR_NAME, OPERATOR_USER, NODE_PUBLIC_IP, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
# POOL_ACCOUNT stays empty for now.
```

Back up `node.env` to a private secrets vault (1Password, age-encrypted file, etc.) **before** you ship it. The deployer is the only point at which the populated file exists outside the box.

### 3. Ship two files to the box

```bash
scp node.env root@<NODE_PUBLIC_IP>:/etc/near-city-nodes/node.env
scp <operator>.pub root@<NODE_PUBLIC_IP>:/etc/near-city-nodes/operator_authorized_keys
```

The `/etc/near-city-nodes/` directory is created by phase 03, so on a fresh box you'll need to create it first:

```bash
ssh root@<NODE_PUBLIC_IP> 'install -d -m 700 /etc/near-city-nodes'
```

### 4. Clone the repo on the box

```bash
ssh root@<NODE_PUBLIC_IP> '
  git clone https://github.com/<org>/near-city-nodes.git /opt/near-city-nodes &&
  cd /opt/near-city-nodes
'
```

### 5. Run bootstrap

```bash
ssh root@<NODE_PUBLIC_IP> 'cd /opt/near-city-nodes && ./bootstrap.sh'
```

Phases run in order 00 -> 11. On transient failures, re-run - completed phases short-circuit on their state markers (`/var/lib/near-city-nodes/bootstrap-state/<phase>.done`). Logs stream to stdout and append to `/var/log/near-city-nodes/bootstrap.log`.

### 6. Confirm the summary banner

Phase 11 prints the validator pubkey, node pubkey, public_addrs string, Grafana URL, and Grafana admin password. If you missed it:

```bash
ssh root@<NODE_PUBLIC_IP> '
  cat /var/lib/near-city-nodes/validator_pubkey.txt;
  cat /root/.grafana_admin_password
'
```

Save the validator pubkey - it's the next step's input.

### 7. Verify the service

```bash
ssh root@<NODE_PUBLIC_IP> 'systemctl is-active neard-mainnet && curl -s http://localhost:3030/status | jq .sync_info'
```

`syncing: true` is normal at this point - the node is downloading state from genesis. Mainnet sync takes ~24-48 h on AX41 NVMe. Watch progress via Grafana (`http://<NODE_PUBLIC_IP>:3000`, admin / generated password).

## Operator post-deploy

### 8. Operator login

The operator should now be able to ssh in:

```bash
ssh <OPERATOR_USER>@<NODE_PUBLIC_IP>
sudo -l   # Lists exactly 8 whitelisted commands
```

### 9. Telegram smoke test (deployer, root)

`update-near.sh` only fires Telegram on real update activity (build, restart, fail, postpone). To confirm wiring at deploy time, the deployer hits both endpoints directly:

```bash
ssh root@<NODE_PUBLIC_IP> '
  source /etc/near-city-nodes/node.env
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=*${OPERATOR_NAME}* | \`[TEST]\` per-node bot wiring" \
    --data-urlencode "parse_mode=Markdown"
  if [[ -n "${TELEGRAM_FLEET_BOT_TOKEN:-}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_FLEET_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_FLEET_CHAT_ID}" \
      --data-urlencode "text=*${OPERATOR_NAME}* | \`[TEST]\` fleet bot wiring" \
      --data-urlencode "parse_mode=Markdown"
  fi
'
```

Expect `{"ok":true,...}` from each curl and the test message in the corresponding Telegram chat. After confirming, the operator will receive Telegram alerts whenever the auto-updater acts (typically silent on no-op `OK already on latest`).

### 10. Hand off the validator pubkey

Send the validator pubkey from step 6 to whoever runs `scripts/deploy-pool.sh`, then proceed to [02-pool-and-stake.md](02-pool-and-stake.md).

---

## Common failure modes

- **Phase 00 fails on RAM check**: the host is below the preflight floor for its `NETWORK` and `BUILD_MODE` (see `00-preflight.sh`; a `build` host needs the RAM to compile neard). Re-order or resize.
- **Phase 04 fails on docker daemon**: kernel cgroups misconfigured. `systemctl status docker` and Hetzner's serial console are your friends.
- **Phase 05 slow at `make release`** (build mode): the cargo build is real CPU work for ~15-20 min on AX41. Not a hang; check `top` / `docker stats`. In `pull` mode phase 05 fetches a prebuilt image instead and returns in seconds.
- **Phase 06 fails downloading genesis**: usually transient; re-run the phase. If persistent, check outbound firewall - needs `s3.amazonaws.com:443`.
- **Phase 07 starts neard but `is-active` fails**: `journalctl -u neard-mainnet -n 50`. Check `/var/lib/neard/.near/config.json` is well-formed (`jq . config.json`). Re-run phase 06 with `--force` to regenerate.
- **Phase 09 starts grafana but Telegram smoke test fails**: contact-points YAML rendered with wrong tokens. Inspect `/etc/grafana/provisioning/alerting/contact-points-primary.yaml` (and `contact-points-fleet.yaml` if fleet vars set). Edit `node.env`, re-run `./bootstrap.sh --phase 09-alerting --force`.
