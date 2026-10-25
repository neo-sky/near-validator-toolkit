#!/bin/bash
# Apply a staged DB-migration upgrade across fleet hosts, one host at a time.
# Each host runs its own update-near.sh apply-staged (epoch gate, snapshot,
# rollback) and must come back on the staged version before the next host is
# touched. A failure, an unreachable host, or an epoch postponement stops the
# rollout where it is, so a half-upgraded fleet never drifts unattended.
#
# Usage: apply-staged-fleet.sh [host ...]
# Hosts come from the arguments, or from FLEET_HOSTS (space-separated) if none
# are given.
# Env: INSTALL_DIR (default /opt/near-city-nodes), SETTLE_SECONDS (default 120),
#      FLEET_HOSTS

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/near-city-nodes}"
SETTLE_SECONDS="${SETTLE_SECONDS:-120}"

HOSTS=("$@")
[[ ${#HOSTS[@]} -gt 0 ]] || read -ra HOSTS <<<"${FLEET_HOSTS:-}"
[[ ${#HOSTS[@]} -gt 0 ]] || {
    echo "no target hosts: pass them as arguments or set FLEET_HOSTS" >&2
    exit 2
}

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
REMOTE_ENV="set -a; . $INSTALL_DIR/.env; set +a"

step() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

remote() {
    local host="$1"; shift
    ssh "${SSH_OPTS[@]}" "$host" "$REMOTE_ENV; $*"
}

staged_version() {
    remote "$1" 'cat "${STAGED_FILE:-/var/lib/near-city-nodes/staged-upgrade}" 2>/dev/null || true'
}

running_state() {
    remote "$1" 'curl -s --max-time 10 "${LOCAL_STATUS_URL:-http://localhost:3030/status}"' \
        | jq -r '"\(.version.version) syncing=\(.sync_info.syncing)"' 2>/dev/null \
        || echo "unreachable"
}

step "staged rollout to ${#HOSTS[@]} host(s), one at a time: ${HOSTS[*]}"
for h in "${HOSTS[@]}"; do
    step "$h"
    ssh "${SSH_OPTS[@]}" "$h" true 2>/dev/null || die "$h unreachable; rollout stopped"

    staged=$(staged_version "$h")
    if [[ -z "$staged" ]]; then
        echo "  nothing staged, skipping"
        continue
    fi
    echo "  staged $staged, running $(running_state "$h")"

    ssh "${SSH_OPTS[@]}" "$h" "sudo $INSTALL_DIR/update-near.sh apply-staged" \
        || die "$h apply-staged failed; rollout stopped, inspect the host before continuing"

    if [[ -n "$(staged_version "$h")" ]]; then
        echo "  postponed by the epoch gate; re-run after the next epoch to continue from $h"
        exit 3
    fi

    state=$(running_state "$h")
    [[ "$state" == "$staged "* ]] || die "$h reports $state, expected $staged; rollout stopped"
    echo "  applied: $state"

    if [[ "$h" != "${HOSTS[-1]}" ]]; then
        echo "  settling ${SETTLE_SECONDS}s before the next host"
        sleep "$SETTLE_SECONDS"
    fi
done

step "done"
