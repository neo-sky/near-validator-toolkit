#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env file not found at $ENV_FILE" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${OPERATOR_NAME:?OPERATOR_NAME must be set in $ENV_FILE}"
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN must be set in $ENV_FILE}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID must be set in $ENV_FILE}"
: "${SERVICE_NAME:?SERVICE_NAME must be set in $ENV_FILE}"
: "${IMAGE_NAME:?IMAGE_NAME must be set in $ENV_FILE}"
: "${DOCKER_BUILD_CONTEXT:?DOCKER_BUILD_CONTEXT must be set in $ENV_FILE}"
: "${VERSION_FILE:?VERSION_FILE must be set in $ENV_FILE}"

NETWORK="${NETWORK:-mainnet}"
NEAR_RPC_URL="${NEAR_RPC_URL:-https://rpc.mainnet.near.org}"
LOCAL_STATUS_URL="${LOCAL_STATUS_URL:-http://localhost:3030/status}"
LOCAL_METRICS_URL="${LOCAL_METRICS_URL:-http://localhost:3030/metrics}"
EPOCH_LENGTH="${EPOCH_LENGTH:-43200}"
MAX_EPOCH_PROGRESS="${MAX_EPOCH_PROGRESS:-75}"
MIN_PEER_COUNT="${MIN_PEER_COUNT:-20}"
STABILIZATION_WAIT="${STABILIZATION_WAIT:-90}"
PAUSE_FILE="${PAUSE_FILE:-/etc/near-city-nodes/pause-upgrades}"
AUDIT_LOG="${AUDIT_LOG:-/var/log/near-city-nodes/update.log}"
KEEP_IMAGES="${KEEP_IMAGES:-3}"
BUILD_MODE="${BUILD_MODE:-build}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"
STAGED_FILE="${STAGED_FILE:-/var/lib/near-city-nodes/staged-upgrade}"
NEAR_DATA_DIR="${NEAR_DATA_DIR:-/var/lib/neard/.near/data}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/var/lib/neard/.near/data.pre-upgrade-snapshot}"

START_TIME=$SECONDS
mkdir -p "$(dirname "$AUDIT_LOG")" "$(dirname "$VERSION_FILE")"

TELEGRAM_DESTS=()
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] \
    && TELEGRAM_DESTS+=("${TELEGRAM_BOT_TOKEN}|${TELEGRAM_CHAT_ID}|primary")
[[ -n "${TELEGRAM_FLEET_BOT_TOKEN:-}" && -n "${TELEGRAM_FLEET_CHAT_ID:-}" ]] \
    && TELEGRAM_DESTS+=("${TELEGRAM_FLEET_BOT_TOKEN}|${TELEGRAM_FLEET_CHAT_ID}|fleet")

log() {
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$OPERATOR_NAME] $*"
    echo "$line" >&2
    printf '%s\n' "$line" >> "$AUDIT_LOG"
}

send_telegram() {
    local message="*${OPERATOR_NAME}* | $1"
    local dest token chat label
    for dest in "${TELEGRAM_DESTS[@]}"; do
        IFS='|' read -r token chat label <<<"$dest"
        curl -s --max-time 15 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
            --data-urlencode "chat_id=${chat}" \
            --data-urlencode "text=${message}" \
            --data-urlencode "parse_mode=Markdown" >/dev/null \
            || log "WARN Telegram delivery failed (dest=$label)"
    done
}

on_error() {
    local line=$1
    local code=$2
    log "FAIL unexpected error on line $line exit=$code"
    send_telegram "\`[FAIL]\` Unexpected error on line ${line} (exit ${code}). Manual intervention required."
}
trap 'on_error $LINENO $?' ERR

get_current_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE"
    else
        echo "unknown"
    fi
}

set_current_version() {
    printf '%s' "$1" > "$VERSION_FILE"
}

get_latest_version() {
    curl -s --max-time 30 "https://api.github.com/repos/near/nearcore/releases/latest" \
        | jq -r '.tag_name' | sed 's/^v//'
}

get_release_body() {
    local tag="$1"
    curl -s --max-time 30 "https://api.github.com/repos/near/nearcore/releases/tags/${tag}" \
        | jq -r '.body // ""'
}

is_security_upgrade() {
    grep -qiE 'SECURITY_UPGRADE:[[:space:]]*TRUE' <<<"$1" && echo "true" || echo "false"
}

is_database_upgrade() {
    grep -qiE 'DATABASE_UPGRADE:[[:space:]]*TRUE' <<<"$1" && echo "true" || echo "false"
}

get_remote_block_height() {
    curl -s --max-time 30 "$NEAR_RPC_URL" \
        -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":"1","method":"status","params":[]}' \
        | jq -r '.result.sync_info.latest_block_height'
}

get_local_epoch_start() {
    curl -s --max-time 10 "$LOCAL_STATUS_URL" | jq -r .sync_info.epoch_start_height
}

check_epoch_progress() {
    local current_block epoch_start blocks_in progress
    current_block=$(get_remote_block_height)
    if [[ -z "$current_block" || "$current_block" == "null" ]]; then
        log "ERROR could not fetch remote block height"
        return 2
    fi
    epoch_start=$(get_local_epoch_start)
    if [[ -z "$epoch_start" || "$epoch_start" == "null" ]]; then
        log "ERROR could not fetch local epoch start (node may be down)"
        return 2
    fi
    blocks_in=$(( current_block - epoch_start ))
    progress=$(( blocks_in * 100 / EPOCH_LENGTH ))
    echo "$progress"
}

health_check_peers() {
    { curl -s --max-time 10 "$LOCAL_METRICS_URL" 2>/dev/null || true; } \
        | { grep '^near_peer_connections{' || true; } \
        | awk '{sum += $2} END {print sum+0}'
}

rollback() {
    local prev_version="$1"
    if [[ -z "$prev_version" || "$prev_version" == "unknown" ]]; then
        log "ROLLBACK no previous version recorded, manual intervention required"
        send_telegram "\`[ROLLBACK]\` Cannot revert (no previous version recorded). Manual intervention required."
        return 1
    fi
    if ! docker image inspect "${IMAGE_NAME}:${prev_version}" >/dev/null 2>&1; then
        log "ROLLBACK previous image ${IMAGE_NAME}:${prev_version} not found locally"
        send_telegram "\`[ROLLBACK]\` Previous image \`${IMAGE_NAME}:${prev_version}\` \
not present. Manual intervention required."
        return 1
    fi
    log "ROLLBACK retag ${IMAGE_NAME}:${prev_version} -> :current"
    send_telegram "\`[ROLLBACK]\` Restoring previous image \`${prev_version}\`..."
    docker tag "${IMAGE_NAME}:${prev_version}" "${IMAGE_NAME}:current"
    set_current_version "$prev_version"
    systemctl restart "$SERVICE_NAME"
    send_telegram "\`[ROLLBACK]\` Service restarted on previous image."
}

prune_old_images() {
    local keep="$1"
    local removed=0
    while IFS= read -r tag; do
        [[ -z "$tag" || "$tag" == "current" || "$tag" == "latest" || "$tag" == "<none>" ]] && continue
        log "PRUNE removing ${IMAGE_NAME}:${tag}"
        docker rmi "${IMAGE_NAME}:${tag}" 2>/dev/null && removed=$((removed + 1)) || \
            log "WARN failed to remove ${IMAGE_NAME}:${tag} (in use?)"
    done < <(docker images "${IMAGE_NAME}" --format '{{.Tag}}' \
                | grep -v -E '^(current|latest|<none>)$' \
                | sort -V -r \
                | tail -n +$((keep + 1)))
    echo "$removed"
}

BUILD_MIN=0
acquire_image() {
    local tag="$1"
    local ref="${IMAGE_NAME}:${tag}"
    BUILD_MIN=0
    if docker image inspect "$ref" >/dev/null 2>&1; then
        log "INFO image $ref already present"
        send_telegram "\`[CACHED]\` Image \`${ref}\` already present."
        return 0
    fi
    case "$BUILD_MODE" in
        build)
            send_telegram "\`[BUILD]\` Building \`${ref}\` from $DOCKER_BUILD_CONTEXT (~15-20min)..."
            local start=$SECONDS
            if ! docker build --build-arg "NEARCORE_TAG=$tag" -t "$ref" "$DOCKER_BUILD_CONTEXT"; then
                log "FAIL docker build for $tag"
                send_telegram "\`[FAIL]\` docker build failed for \`${tag}\`. No changes applied."
                return 1
            fi
            BUILD_MIN=$(( (SECONDS - start) / 60 ))
            log "OK build complete for $tag in ${BUILD_MIN}min"
            ;;
        pull)
            [[ -n "$IMAGE_REGISTRY" ]] || {
                log "FATAL BUILD_MODE=pull but IMAGE_REGISTRY is unset"
                send_telegram "\`[FAIL]\` BUILD_MODE=pull but IMAGE_REGISTRY is empty. Set it in node.env."
                return 1
            }
            local src="${IMAGE_REGISTRY}/${IMAGE_NAME}:${tag}"
            send_telegram "\`[PULL]\` Fetching \`${src}\`..."
            if ! docker pull "$src"; then
                log "FAIL docker pull $src"
                send_telegram "\`[FAIL]\` Could not pull \`${src}\`. No changes applied."
                return 1
            fi
            docker tag "$src" "$ref"
            log "OK pulled $tag from $src"
            ;;
        stage)
            log "NEEDS-IMAGE $tag absent and BUILD_MODE=stage (host does not build)"
            send_telegram "\`[NEEDS IMAGE]\` \`${tag}\` is not present and this host does not build \
(BUILD_MODE=stage). Deliver it with \`push-image-to-fleet.sh ${tag}\`; it applies on the next run."
            return 1
            ;;
        *)
            log "FATAL unknown BUILD_MODE=$BUILD_MODE"
            send_telegram "\`[FAIL]\` Invalid BUILD_MODE \`${BUILD_MODE}\` (expected build, pull, or stage)."
            return 1
            ;;
    esac
    return 0
}

apply_rollback() {
    local prev="$1" staged="$2" migrated="$3"
    trap - ERR
    set +e
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    if (( migrated )); then
        log "APPLY ROLLBACK post-migration: restore snapshot + $prev"
        send_telegram "\`[ROLLBACK]\` \`${staged}\` failed after migration. Restoring DB snapshot + \`${prev}\`."
        if [[ -d "$SNAPSHOT_DIR" ]]; then
            rm -rf "$NEAR_DATA_DIR"
            mv "$SNAPSHOT_DIR" "$NEAR_DATA_DIR"
        else
            send_telegram "\`[ROLLBACK]\` WARNING snapshot missing at \`${SNAPSHOT_DIR}\`; DB left as-is, manual recovery needed."
        fi
    else
        log "APPLY ROLLBACK pre-migration: data intact, restart $prev"
        send_telegram "\`[ROLLBACK]\` \`${staged}\` apply failed before migration; data intact. Restarting \`${prev}\`."
        rm -rf "$SNAPSHOT_DIR" 2>/dev/null || true
    fi
    docker tag "${IMAGE_NAME}:${prev}" "${IMAGE_NAME}:current" 2>/dev/null || true
    set_current_version "$prev"
    systemctl start "$SERVICE_NAME" 2>/dev/null || true
    send_telegram "\`[ROLLBACK]\` Restored \`${prev}\`. Investigate before re-staging."
    exit 1
}

apply_staged() {
    [[ -f "$STAGED_FILE" ]] || { log "APPLY no staged upgrade at $STAGED_FILE"; exit 1; }
    local staged prev
    staged=$(cat "$STAGED_FILE")
    prev=$(get_current_version)

    if ! docker image inspect "${IMAGE_NAME}:${staged}" >/dev/null 2>&1; then
        log "APPLY staged image ${IMAGE_NAME}:${staged} missing"
        send_telegram "\`[FAIL]\` Staged image \`${staged}\` not present. Re-stage before applying."
        exit 1
    fi

    local progress
    progress=$(check_epoch_progress) || {
        send_telegram "\`[ABORT]\` apply-staged: could not read epoch state."
        exit 1
    }
    if (( progress > MAX_EPOCH_PROGRESS )); then
        log "APPLY postpone epoch ${progress}% > ${MAX_EPOCH_PROGRESS}%"
        send_telegram "\`[POSTPONE]\` apply-staged: epoch ${progress}% exceeds ${MAX_EPOCH_PROGRESS}%. Re-run after next epoch."
        exit 0
    fi

    local migrated=0
    trap 'apply_rollback "$prev" "$staged" "$migrated"' ERR

    send_telegram "\`[APPLY]\` Staged \`${prev}\` -> \`${staged}\` (DB migration). Epoch ${progress}%. Stopping, snapshotting, migrating."
    log "APPLY stop $SERVICE_NAME"
    systemctl stop "$SERVICE_NAME"

    log "APPLY snapshot $NEAR_DATA_DIR -> $SNAPSHOT_DIR"
    rm -rf "$SNAPSHOT_DIR"
    cp -al "$NEAR_DATA_DIR" "$SNAPSHOT_DIR"

    log "APPLY retag ${IMAGE_NAME}:${staged} -> :current"
    docker tag "${IMAGE_NAME}:${staged}" "${IMAGE_NAME}:current"
    set_current_version "$staged"

    log "APPLY start $SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    migrated=1

    local up=0 i
    for (( i = 0; i < 60; i++ )); do
        curl -s --max-time 3 "$LOCAL_STATUS_URL" >/dev/null 2>&1 && { up=1; break; }
        sleep 5
    done
    sleep "$STABILIZATION_WAIT"

    local running peers
    running=$(curl -s --max-time 10 "$LOCAL_STATUS_URL" | jq -r '.version.version' 2>/dev/null || echo "")
    peers=$(health_check_peers || echo 0); peers="${peers:-0}"

    if (( up == 1 )) && systemctl is-active --quiet "$SERVICE_NAME" \
        && [[ "$running" == "$staged" ]] && (( peers >= MIN_PEER_COUNT )); then
        trap - ERR
        log "APPLY OK version=$running peers=$peers"
        send_telegram "\`[OK]\` Applied \`${staged}\`, peers ${peers}, epoch ${progress}%. Snapshot kept at \`${SNAPSHOT_DIR}\` (remove after a stable day)."
        rm -f "$STAGED_FILE"
        exit 0
    fi

    log "APPLY unhealthy up=$up version=$running peers=$peers"
    apply_rollback "$prev" "$staged" "$migrated"
}

if [[ "${1:-}" == "apply-staged" ]]; then
    log "START apply-staged"
    apply_staged
fi

log "START update check"

if [[ -f "$PAUSE_FILE" ]]; then
    log "PAUSED $PAUSE_FILE exists, skipping run"
    exit 0
fi

LATEST=$(get_latest_version)
CURRENT=$(get_current_version)
log "INFO current=$CURRENT latest=$LATEST"

if [[ -z "$LATEST" || "$LATEST" == "null" ]]; then
    log "ERROR could not fetch latest release from GitHub"
    send_telegram "\`[WARN]\` Could not fetch nearcore latest release. Will retry on next cron tick."
    exit 1
fi

if [[ "$CURRENT" == "$LATEST" ]]; then
    log "OK already on latest $CURRENT"
    exit 0
fi

RELEASE_BODY=$(get_release_body "$LATEST")
IS_SECURITY=$(is_security_upgrade "$RELEASE_BODY")
IS_DATABASE=$(is_database_upgrade "$RELEASE_BODY")
log "INFO release flags security=$IS_SECURITY database=$IS_DATABASE"

if [[ "$IS_DATABASE" == "true" ]]; then
    log "DATABASE_UPGRADE detected for $LATEST; staging (not auto-applying)"
    acquire_image "$LATEST" || exit 1
    echo "$LATEST" > "$STAGED_FILE"
    log "STAGED $LATEST at $STAGED_FILE"
    send_telegram "\`[ATTENTION]\` \`${LATEST}\` needs a DB migration + manual review. Image is built and staged. \
Read the release notes for config-breaking changes, then apply with: \
\`sudo /opt/near-city-nodes/update-near.sh apply-staged\`"
    exit 0
fi

if [[ "$IS_SECURITY" == "true" ]]; then
    log "SECURITY release noted"
    send_telegram "\`[SECURITY]\` Release \`$LATEST\` flagged \`SECURITY_UPGRADE: TRUE\`. \
Will apply at the next epoch-safe window."
fi

send_telegram "\`[UPDATE]\` Available: \`$CURRENT\` -> \`$LATEST\`. Checking epoch safety."

PROGRESS=$(check_epoch_progress) || {
    send_telegram "\`[ABORT]\` Could not read epoch state. Will retry next cron."
    exit 1
}
log "INFO pre-build epoch_progress=${PROGRESS}%"

if (( PROGRESS > MAX_EPOCH_PROGRESS )); then
    log "POSTPONE epoch ${PROGRESS}% > ${MAX_EPOCH_PROGRESS}%"
    send_telegram "\`[POSTPONE]\` Epoch ${PROGRESS}% exceeds safety limit \
${MAX_EPOCH_PROGRESS}%. Will retry after next epoch."
    exit 0
fi

acquire_image "$LATEST" || exit 1

PROGRESS=$(check_epoch_progress) || {
    send_telegram "\`[ABORT]\` Could not re-check epoch. Image \`${LATEST}\` built but not applied."
    exit 1
}
log "INFO post-build epoch_progress=${PROGRESS}%"

if (( PROGRESS > MAX_EPOCH_PROGRESS )); then
    log "POSTPONE post-build epoch ${PROGRESS}% > ${MAX_EPOCH_PROGRESS}%"
    send_telegram "\`[POSTPONE]\` Build done but epoch now ${PROGRESS}%. \
Image \`${LATEST}\` cached, will retag on next safe window."
    exit 0
fi

log "RETAG ${IMAGE_NAME}:${LATEST} -> :current (was $CURRENT)"
send_telegram "\`[RESTART]\` Epoch ${PROGRESS}%. Retagging \`current\` -> \`${LATEST}\`, restarting service."
docker tag "${IMAGE_NAME}:${LATEST}" "${IMAGE_NAME}:current"
set_current_version "$LATEST"

log "RESTART $SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

log "WAIT stabilization ${STABILIZATION_WAIT}s"
sleep "$STABILIZATION_WAIT"

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    log "FAIL service did not start"
    send_telegram "\`[FAIL]\` Service did not come up after restart. Rolling back to \`${CURRENT}\`."
    rollback "$CURRENT"
    exit 1
fi

PEERS=$(health_check_peers)
PEERS="${PEERS:-0}"

if [[ "$PEERS" == "0" ]]; then
    log "FAIL zero peers after restart"
    send_telegram "\`[FAIL]\` Zero peers after restart. Rolling back to \`${CURRENT}\`."
    rollback "$CURRENT"
    exit 1
fi

if (( PEERS < MIN_PEER_COUNT )); then
    log "WARN low peers=$PEERS min=$MIN_PEER_COUNT"
    send_telegram "\`[WARN]\` Updated to \`${LATEST}\`. Peers ${PEERS} below threshold ${MIN_PEER_COUNT}. Monitoring."
else
    log "OK healthy peers=$PEERS"
    send_telegram "\`[OK]\` Updated to \`${LATEST}\`, peers ${PEERS}, epoch ${PROGRESS}%."
fi

log "CLEANUP keeping last $KEEP_IMAGES versioned images"
PRUNED=$(prune_old_images "$KEEP_IMAGES")
log "CLEANUP pruned $PRUNED images"

elapsed=$(( SECONDS - START_TIME ))
printf -v elapsed_fmt "%02d:%02d:%02d" $(( elapsed / 3600 )) $(( (elapsed % 3600) / 60 )) $(( elapsed % 60 ))
if [[ "$BUILD_MODE" == "build" ]]; then
    log "DONE total=${elapsed_fmt} build=${BUILD_MIN}min"
    send_telegram "\`[DONE]\` Total ${elapsed_fmt}, build ${BUILD_MIN}min."
else
    log "DONE total=${elapsed_fmt}"
    send_telegram "\`[DONE]\` Total ${elapsed_fmt}."
fi

exit 0
