# 03 - Day-to-day operations

For the operator (`OPERATOR_USER` on the box). All commands use the limited sudo grant from `/etc/sudoers.d/90-cityops`.

## Pause auto-updates (maintenance window)

```bash
sudo touch /etc/near-city-nodes/pause-upgrades
```

The next cron tick (02:00, 10:00, 18:00 UTC) will log `PAUSED` and exit. To resume:

```bash
sudo rm /etc/near-city-nodes/pause-upgrades
```

## Force an immediate update check

```bash
sudo /opt/near-city-nodes/update-near.sh
```

Output is mirrored to `/var/log/near-city-nodes/update.log`. Telegram messages fire on actual upgrade activity (build, restart, done) - silent on no-op `OK already on latest`.

## Restart neard manually

```bash
sudo systemctl restart neard-mainnet
```

**Only restart inside the epoch-safe window**: epoch progress < 75%. Check first:

```bash
curl -s http://localhost:3030/status | jq -r '
  .sync_info | "epoch_progress = " + (((.latest_block_height - .epoch_start_height) * 100 / 43200) | floor | tostring) + "%"'
```

Mid-epoch restarts cause missed chunk endorsements and risk kickout. The auto-updater enforces this for upgrades; a manual restart is your responsibility.

## Rollback after a bad upgrade

The auto-updater rolls back automatically if the post-restart health check fails (zero peers). For manual rollback to a known-good image:

```bash
docker tag nearcore:<previous-version> nearcore:current
sudo systemctl restart neard-mainnet
echo <previous-version> | sudo tee /var/lib/near-city-nodes/current_version
```

Available versions:

```bash
docker images nearcore --format '{{.Tag}}\t{{.CreatedSince}}'
```

`KEEP_IMAGES` in `node.env` (default 3) governs how far back rollback can go.

## Database-migration releases (staged upgrades)

Routine releases are applied automatically. A release flagged `DATABASE_UPGRADE: TRUE` is **not** auto-applied, because a database migration is irreversible for the old binary (once neard migrates the on-disk format, the previous image can no longer open it) and such releases sometimes carry config-breaking changes that no machine-readable flag signals. The most recent example: 2.13 stopped accepting `state_sync.sync: ExternalStorage` and exits on startup if it is set. No flag announces that; it is only in the release-notes prose. So a human reads the notes before applying.

When the updater sees a DB-migration release it does the slow, safe part for you: it obtains the image (building or pulling it per `BUILD_MODE`), records the version at `STAGED_FILE`, and Telegrams:

> `[ATTENTION]` `<version>` needs a DB migration + manual review. Image is built and staged. Read the release notes ..., then apply with: `sudo /opt/near-city-nodes/update-near.sh apply-staged`

To apply after reviewing the release notes (in particular, check `config.json` for any field the release drops):

```bash
sudo /opt/near-city-nodes/update-near.sh apply-staged
```

`apply-staged` runs the guarded sequence: epoch-safe check, stop neard, hardlink-snapshot the data dir (`SNAPSHOT_DIR`, near-instant), retag and start on the new version (neard migrates the DB on boot), then verify the running version and peer count. If the new version comes up unhealthy it **restores the DB snapshot and the previous image** and restarts, then alerts. On success the snapshot is kept at `SNAPSHOT_DIR`; remove it after a stable day:

```bash
sudo rm -rf /var/lib/neard/.near/data.pre-upgrade-snapshot
```

The epoch-safety gate applies here exactly as it does to routine upgrades; `apply-staged` postpones itself if the node is past `MAX_EPOCH_PROGRESS`.

## Telegram smoke test

`update-near.sh` only fires Telegram on real upgrade activity (build, restart, fail, postpone). To exercise both bot wirings without waiting for a release, hit each endpoint directly from root:

```bash
source /etc/near-city-nodes/node.env
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=*${OPERATOR_NAME}* | \`[TEST]\` per-node bot"
if [[ -n "${TELEGRAM_FLEET_BOT_TOKEN:-}" ]]; then
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_FLEET_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_FLEET_CHAT_ID}" \
    --data-urlencode "text=*${OPERATOR_NAME}* | \`[TEST]\` fleet bot"
fi
```

Each call should return `{"ok":true,...}` and the test message should land in the corresponding chat.

## Fleet aggregator bot setup (optional)

For ops leads who want every alert from every node in a single DM stream alongside the per-node group bots. One bot, one chat, same `node.env` values across every box.

Setup (one-time, deployer side):

1. **Create the fleet bot via @BotFather**: send `/newbot` to @BotFather, name it (e.g. `FleetBot`). Capture the bot token.
2. **Hand the bot to the ops lead**: lead sends `/start` to the bot from their personal Telegram. This creates a 1:1 chat the bot can post to.
3. **Surface the chat_id**: visit `https://api.telegram.org/bot<TOKEN>/getUpdates` after the `/start`. Find the `result[].message.chat.id` field - that's the chat_id (positive integer for DMs, negative for groups).
4. **Populate per-box `node.env`** on every node in the fleet:
   ```
   TELEGRAM_FLEET_BOT_TOKEN=<bot token from step 1>
   TELEGRAM_FLEET_CHAT_ID=<chat_id from step 3>
   ```
5. **Re-render alerting on each box**:
   ```bash
   ssh root@<box> 'cd /opt/near-city-nodes && ./bootstrap.sh --phase 09-alerting --force'
   ```
   Phase 09 detects the fleet vars, renders `contact-points-fleet.yaml`, and Grafana picks up the new contactPoint on its next reload.

Verify with the same two-bot direct-curl pattern from the [Telegram smoke test](#telegram-smoke-test) section. Both messages should arrive: the per-node bot in its group, and the fleet bot in the aggregator chat. If only the per-node fires, the fleet vars did not reach `update-near.sh`'s environment, check that the `TELEGRAM_DESTS` array build at the top of the script sees both `${TELEGRAM_FLEET_BOT_TOKEN}` and `${TELEGRAM_FLEET_CHAT_ID}` non-empty.

Disable: clear both `TELEGRAM_FLEET_*` vars in `node.env` and re-run `bootstrap.sh --phase 09-alerting --force`. Phase 09 deletes the fleet contact-point file; Grafana logs an orphan-route warning about `telegram-fleet` but the primary route stays functional.

## Grafana access

`http://<NODE_PUBLIC_IP>:3000` (or via SSH tunnel if `GRAFANA_BIND_ADDRESS=127.0.0.1`):

```bash
ssh -L 3000:127.0.0.1:3000 <OPERATOR_USER>@<NODE_PUBLIC_IP>
# then visit http://localhost:3000
```

Admin credentials in `/root/.grafana_admin_password` (deployer-only, requires root). Rotate every ~90 days:

```bash
sudo grafana-cli admin reset-admin-password <new-pw>
echo <new-pw> | sudo tee /root/.grafana_admin_password
sudo chmod 600 /root/.grafana_admin_password
```

### Removing an orphan provisioned dashboard (Grafana 13+)

If you rename a dashboard's `uid` in `/var/lib/grafana/dashboards/*.json`, Grafana keeps the OLD entry as an orphan. The legacy `dashboard` table is empty in Grafana 13 - actual storage is the **unified storage** `resource` and `resource_history` tables. The HTTP API `DELETE /api/dashboards/uid/<uid>` returns `provisioned dashboard cannot be deleted`, and `disableDeletion: false` doesn't help.

To remove an orphan:

```bash
sudo systemctl stop grafana-server
sudo sqlite3 /var/lib/grafana/grafana.db \
  "DELETE FROM resource WHERE name='<orphan-uid>'; DELETE FROM resource_history WHERE name='<orphan-uid>';"
sudo systemctl start grafana-server
```

Grafana rebuilds its search index from the resource table on startup.

## Log locations

| File | Contents |
|---|---|
| `/var/log/near-city-nodes/update.log` | Auto-updater audit trail (every cron tick + manual run) |
| `/var/log/near-city-nodes/cron.log` | Cron-captured stdout from `update-near.sh` |
| `/var/log/near-city-nodes/bootstrap.log` | Phase script runs |
| `/var/log/grafana/grafana.log` | Grafana server log |
| `/var/log/prometheus/prometheus.log` | Prometheus scrape log |
| `journalctl -u neard-mainnet` | neard container stdout |
| `journalctl -u fail2ban` | SSH ban events |

All `/var/log/near-city-nodes/*.log` rotate weekly (12 weeks retention) via `/etc/logrotate.d/near-city-nodes`.

## Telegram alert reference

Severity routing: `critical` notifies immediately and repeats hourly while firing. `warning` waits 30 s for grouping then repeats every 4 h.

| Alert | Severity | Trigger |
|---|---|---|
| Node Down | critical | `up{job="neard"} == 0` for 1 min |
| Sync Stalled | critical | `increase(near_block_height_head[5m]) < 1` for 2 min |
| Head Lag High | warning | `near_head_lag_seconds > 30` for 5 min |
| Low Peer Count | warning | `sum(near_peer_connections) < 10` for 3 min |
| Host Memory Critical | critical | mem usage > 90% for 2 min |
| Root Disk 85% | warning | `/` > 85% for 10 min |
| Root Disk 95% | critical | `/` > 95% for 1 min |
