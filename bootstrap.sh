#!/bin/bash
# NEAR validator bootstrap. Phased install: see bootstrap/phases/.
# Usage:
#   bootstrap.sh                       run all pending phases
#   bootstrap.sh --phase NN-name       run exactly one phase
#   bootstrap.sh --from NN             run from this phase to the end
#   bootstrap.sh --to NN               run from the start up to this phase
#   bootstrap.sh --force               re-run phases even if their marker exists
#   bootstrap.sh --list                show phases and their state

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASES_DIR="$SCRIPT_DIR/bootstrap/phases"
LIB_DIR="$SCRIPT_DIR/bootstrap/lib"
STATE_DIR="${STATE_DIR:-/var/lib/near-city-nodes/bootstrap-state}"
LOG_FILE="${LOG_FILE:-/var/log/near-city-nodes/bootstrap.log}"

export STATE_DIR LOG_FILE

# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"

ONLY_PHASE=""
FROM_PHASE=""
TO_PHASE=""
FORCE=0
LIST=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase) ONLY_PHASE="$2"; shift 2 ;;
        --from)  FROM_PHASE="$2"; shift 2 ;;
        --to)    TO_PHASE="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --list)  LIST=1; shift ;;
        -h|--help)
            sed -n '2,9p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mapfile -t PHASES < <(find "$PHASES_DIR" -maxdepth 1 -name '[0-9][0-9]-*.sh' -printf '%f\n' | sort)
[[ ${#PHASES[@]} -gt 0 ]] || { echo "no phases found in $PHASES_DIR" >&2; exit 1; }

phase_id() { echo "${1%.sh}"; }
phase_num() { echo "${1%%-*}"; }

if (( LIST )); then
    printf '%-22s %s\n' "PHASE" "STATE"
    for p in "${PHASES[@]}"; do
        id="$(phase_id "$p")"
        state="pending"
        [[ -f "$STATE_DIR/$id.done" ]] && state="done"
        printf '%-22s %s\n' "$id" "$state"
    done
    exit 0
fi

run_phase() {
    local script="$1"
    local id; id="$(phase_id "$script")"
    mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
    if (( FORCE )); then
        rm -f "$STATE_DIR/$id.done"
    elif [[ -f "$STATE_DIR/$id.done" ]]; then
        echo "[$id] skip (marker exists; use --force to re-run)"
        return 0
    fi
    echo "[$id] start"
    PHASE="$id" \
    STATE_DIR="$STATE_DIR" \
    LOG_FILE="$LOG_FILE" \
    REPO_DIR="$SCRIPT_DIR" \
        bash "$PHASES_DIR/$script"
    echo "[$id] done"
}

if [[ -n "$ONLY_PHASE" ]]; then
    matched=""
    for p in "${PHASES[@]}"; do
        [[ "$(phase_id "$p")" == "$ONLY_PHASE" ]] && matched="$p" && break
    done
    [[ -n "$matched" ]] || { echo "no phase matches: $ONLY_PHASE" >&2; exit 1; }
    run_phase "$matched"
    exit 0
fi

for p in "${PHASES[@]}"; do
    n="$(phase_num "$p")"
    if [[ -n "$FROM_PHASE" ]]; then
        from_n="${FROM_PHASE%%-*}"
        (( 10#$n < 10#$from_n )) && continue
    fi
    if [[ -n "$TO_PHASE" ]]; then
        to_n="${TO_PHASE%%-*}"
        (( 10#$n > 10#$to_n )) && continue
    fi
    run_phase "$p"
done

echo
echo "bootstrap complete"
