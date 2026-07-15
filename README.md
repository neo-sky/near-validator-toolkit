# near-validator-toolkit

A phased bootstrap toolkit for deploying and operating NEAR Protocol validator nodes. One command turns a fresh Ubuntu host into a hardened, monitored, auto-updating mainnet validator.

The toolkit is built around one validator per host. Everything a node needs (system hardening, the neard image, monitoring, alerting, and an epoch-safe auto-updater) is installed by a single idempotent `bootstrap.sh` run, configured entirely from one per-host environment file.

## What it deploys

Running `bootstrap.sh` on a fresh host installs, in order:

1. **Preflight** checks (OS, RAM, disk, connectivity)
2. **Base** packages, timezone, NTP
3. **Hardening**: sshd drop-in, sysctl, UFW, fail2ban, unattended-upgrades
4. **Users**: dedicated `neard` system user, operator user with a limited sudo grant
5. **Docker**
6. **neard image**: built from a pinned `nearcore` release tag, or pulled from a registry (see [Image delivery](#image-delivery))
7. **neard init**: genesis + config download, key generation, `public_addrs` injection
8. **systemd** unit for the validator container
9. **Monitoring**: Prometheus + node-exporter + Grafana with a provisioned dashboard
10. **Alerting**: Grafana alert rules routed to Telegram (per-node, plus an optional fleet aggregator)
11. **Scheduling**: cron-driven auto-updater + log rotation
12. **Summary**: prints the validator public key and next steps

The auto-updater (`update-near.sh`) checks for new `nearcore` releases, obtains the new image, swaps it, and restarts the validator only inside the epoch-safe window. It rolls back automatically if the node comes up unhealthy, and it stages releases flagged as database migrations for a one-command manual apply instead of applying them unattended.

## Image delivery

The neard image is obtained according to `BUILD_MODE` in `node.env`:

- **`build`** compiles neard from source on the host. Needs a build-class machine (~60 GB RAM); the default for bare-metal validators.
- **`pull`** fetches a prebuilt image from `IMAGE_REGISTRY` (e.g. `ghcr.io/<org>`). For hosts that cannot compile neard, such as small cloud instances. Images are published by [`.github/workflows/publish-image.yml`](.github/workflows/publish-image.yml), which builds each `nearcore` release and pushes it to the registry.
- **`stage`** never fetches; it expects the image to have been delivered out of band by [`scripts/push-image-to-fleet.sh`](scripts/push-image-to-fleet.sh), the airgapped fallback.

`build` and `pull` cover the deploy and every subsequent auto-update through the same code path, so a host never changes how it obtains images after the first deploy.

## Prerequisites

- A host running **Ubuntu 22.04, 24.04, or 26.04 LTS**. See [`bootstrap/phases/00-preflight.sh`](bootstrap/phases/00-preflight.sh) for the exact RAM/disk gates (a `build` host also needs the RAM to compile neard).
- An **SSH keypair** for the operator account.
- A **Telegram bot** (via [@BotFather](https://t.me/BotFather)) and the chat ID of the channel that should receive alerts.
- For `pull` mode: a registry the host can reach (`ghcr.io` needs no credentials for a public package).
- For the on-chain pool deploy: a funded NEAR account and [`near-cli-rs`](https://github.com/near/near-cli-rs) on your workstation.

## Quick start

```bash
# On your workstation: build the per-host config from the template
cp .env.example node.env
# Fill in OPERATOR_NAME, OPERATOR_USER, NODE_PUBLIC_IP, TELEGRAM_BOT_TOKEN,
# TELEGRAM_CHAT_ID, and (for pull mode) BUILD_MODE=pull + IMAGE_REGISTRY

# Ship the config + operator public key to the host
scp node.env      root@<host>:/etc/near-city-nodes/node.env
scp operator.pub  root@<host>:/etc/near-city-nodes/operator_authorized_keys

# Clone and run on the host
ssh root@<host> '
  git clone https://github.com/<org>/near-validator-toolkit.git /opt/near-city-nodes &&
  cd /opt/near-city-nodes &&
  ./bootstrap.sh
'
```

`scripts/deploy-cloud-node.sh` wraps this whole sequence for pull-mode hosts (config, key, bootstrap, verify) in one command from your workstation. Mainnet sync from genesis takes roughly 24-48h. The full deploy-to-stake walkthrough is in [`runbook/`](runbook/).

## Pool deploy and staking

The host runs the validator; a separate staking pool contract binds delegated stake to the validator key. The operator-side scripts in [`scripts/`](scripts/) handle the on-chain side from a workstation with `near-cli-rs`:

- `deploy-pool.sh` creates the staking pool via the `pool.near` factory
- `verify-pool.sh` runs read-only checks against a deployed pool (owner, staking key, fee, keyless invariant, code hash)
- `lock-pool.sh` confirms the pool holds no full-access keys

See [`runbook/02-pool-and-stake.md`](runbook/02-pool-and-stake.md) for the full sequence, including the pre-deploy hard gate.

## Repository layout

```
bootstrap.sh              Single entry point; dispatches phases
bootstrap/lib/            Shared shell helpers (logging, rendering)
bootstrap/phases/         The 12 numbered install phases
update-near.sh            Cron-driven, epoch-safe auto-updater
Dockerfile                Two-stage neard build
.github/workflows/        CI checks and the registry image publisher
systemd/                  Validator service unit
templates/                Config templates rendered per host (ssh, ufw, fail2ban,
                          sysctl, prometheus, grafana, cron, logrotate, ...)
grafana/                  Per-validator dashboard (uses a $node template variable)
scripts/                  Node deploy + operator-side pool deploy / verify / lock
runbook/                  Numbered operator + deployer guide
.env.example              Canonical per-host configuration template
```

## Configuration

Every per-host value lives in a single file at `/etc/near-city-nodes/node.env`, built from [`.env.example`](.env.example). The repository contains no host-specific values, secrets, or keys. Phase scripts render templates from `node.env` at deploy time.

State markers live outside the repo at `/var/lib/near-city-nodes/bootstrap-state/`, so `git pull` and `git clean` never touch host state. Re-running `bootstrap.sh` on a healthy host is a no-op; individual phases can be re-run with `--phase NN-name --force`.

## Security model

- **No secrets in the repository.** Bot tokens, the Grafana admin password, and all per-host config live only in `node.env` on the box (mode 600), which is excluded by `.gitignore`.
- **Validator and node keys are generated on the host** and never leave it through this toolkit. Back them up off-box for disaster recovery.
- **Operators get a limited sudo grant**, not root: start/stop/restart the validator, run the updater, toggle the upgrade pause. Nothing else.
- **The staking pool is keyless** by construction (deployed via the canonical factory); `lock-pool.sh` verifies this.

## License

MIT License. See [LICENSE](LICENSE).
