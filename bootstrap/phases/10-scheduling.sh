#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0

log "INFO install /etc/cron.d/near-city-nodes-updater"
install -m 644 -o root -g root \
    "$REPO_DIR/templates/cron/near-city-nodes-updater" \
    /etc/cron.d/near-city-nodes-updater

log "INFO install /etc/logrotate.d/near-city-nodes"
install -m 644 -o root -g root \
    "$REPO_DIR/templates/logrotate/near-city-nodes" \
    /etc/logrotate.d/near-city-nodes
logrotate --debug /etc/logrotate.d/near-city-nodes >/dev/null 2>&1 \
    || die "logrotate config rejected"

log "OK cron + logrotate installed"
mark_phase_done
