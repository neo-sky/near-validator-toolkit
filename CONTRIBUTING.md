# Contributing

## Ground rules

- This toolkit deploys mainnet validators. Changes that touch the bootstrap phases, the auto-updater, or the pool scripts are operationally sensitive; explain the blast radius in the PR.
- Never commit host-specific values: validator IPs, pool account names, public keys, bot tokens, chat IDs, or anything from a populated `node.env`. The repository stays free of deployment state.
- Keep phases small and idempotent. A phase must be safe to re-run with `--force`.

## Before opening a PR

Run locally what CI runs:

```bash
# bash syntax
git ls-files '*.sh' | xargs -n1 bash -n

# shellcheck (if installed)
git ls-files '*.sh' | xargs shellcheck

# yaml / json validity
python3 -c "import glob,yaml; [list(yaml.safe_load_all(open(f))) for f in glob.glob('**/*.y*ml', recursive=True)]"
python3 -c "import glob,json; [json.load(open(f)) for f in glob.glob('**/*.json', recursive=True)]"
```

## Style

- POSIX-friendly bash, `set -euo pipefail`, quote expansions.
- No host-specific examples in code or docs; use placeholders (`<host>`, `<pool-name>`, `<NODE_PUBLIC_IP>`).
- Configuration flows through `node.env` and the template renderer, not hardcoded values.
