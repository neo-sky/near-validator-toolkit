# shellcheck shell=bash
# Shared helpers for bootstrap phase scripts.
# Source this from each phase: source "$(dirname "$0")/../lib/common.sh"

set -Eeuo pipefail

# shellcheck disable=SC2034  # consumed by the phase scripts that source this file
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="${STATE_DIR:-/var/lib/near-city-nodes/bootstrap-state}"
LOG_FILE="${LOG_FILE:-/var/log/near-city-nodes/bootstrap.log}"
ENV_FILE="${ENV_FILE:-/etc/near-city-nodes/node.env}"

log() {
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [${PHASE:-bootstrap}] $*"
    echo "$line"
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s\n' "$line" >> "$LOG_FILE"
}

die() {
    log "FATAL $*"
    exit 1
}

on_err() {
    local code=$?
    local line=${BASH_LINENO[0]:-?}
    local cmd=${BASH_COMMAND:-?}
    log "FATAL phase=${PHASE:-unknown} exit=$code line=$line cmd=$cmd"
}
trap on_err ERR

retry() {
    local attempts="$1"; shift
    local delay="$1"; shift
    local n=0
    until "$@"; do
        n=$((n + 1))
        if (( n >= attempts )); then
            return 1
        fi
        log "RETRY $n/$attempts after ${delay}s: $*"
        sleep "$delay"
    done
}

mark_phase_done() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/${PHASE}.done"
}

phase_done() {
    [[ -f "$STATE_DIR/${PHASE}.done" ]]
}

load_env() {
    [[ -f "$ENV_FILE" ]] || die "env file not found at $ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
}

require_var() {
    local name="$1"
    local val
    val="$(eval "echo \"\${$name:-}\"")"
    [[ -n "$val" ]] || die "required env var $name is empty (set in $ENV_FILE)"
}
