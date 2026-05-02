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
ufw allow 3000/tcp comment 'Grafana'

ufw --force enable
ufw status verbose
