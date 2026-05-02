# Validator node runbook

Sequential operator + deployer guide. Follow in order on first deploy; jump to 03 / 99 for ongoing ops.

1. [01-deploy.md](01-deploy.md) - order Hetzner, prep `node.env`, run `bootstrap.sh`, wait for sync.
2. [02-pool-and-stake.md](02-pool-and-stake.md) - hand off validator pubkey, deploy pool, call `update_staking_key`, watch inclusion.
3. [03-operations.md](03-operations.md) - pause/resume updates, rollback, Telegram smoke test, log locations.
4. [99-recovery.md](99-recovery.md) - re-run a phase, restore validator key, full rebuild.

The repo's design assumes one validator per host. Two operator-side prerequisites:
- An SSH keypair (the operator's, not the deployer's).
- A Telegram bot via @BotFather and the chat_id of the channel that will receive alerts.
