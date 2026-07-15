#!/bin/bash
# Apply UFW rules for a NEAR validator node. Idempotent: rules are deduped by signature.
# Run as root from phase 02-harden.sh.

set -euo pipefail

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

ufw allow 22/tcp comment 'SSH'
ufw allow 24567/tcp comment 'NEAR p2p'

if [[ "${GRAFANA_BIND_ADDRESS:-127.0.0.1}" == "0.0.0.0" ]]; then
    ufw allow 3000/tcp comment 'Grafana'
fi

ufw --force enable
ufw status verbose
