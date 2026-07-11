#!/bin/bash
# Deploy one NEAR validator node onto a provisioned Ubuntu host.
# Usage:
#   NODE_BOT_TOKEN=<token> deploy-cloud-node.sh <ssh-host> <operator-name> <public-ipv4> <chat-id>
#
# The Telegram bot token is read from NODE_BOT_TOKEN so it never lands in argv.
# REF_HOST supplies the fleet Telegram credentials and the nearcore image; it must
# already be deployed. FORCE=1 permits redeploying a host that carries a pool account.
#
# Env: REF_HOST (default cloud-3), IMAGE_TAG, OPERATOR_PUBKEY, TRANSFER_TIMEOUT, FORCE

set -euo pipefail

REF_HOST="${REF_HOST:-cloud-3}"
IMAGE_TAG="${IMAGE_TAG:-2.13.0}"
OPERATOR_PUBKEY="${OPERATOR_PUBKEY:-$HOME/.ssh/citynode_fleet.pub}"
TRANSFER_TIMEOUT="${TRANSFER_TIMEOUT:-900}"
FORCE="${FORCE:-0}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE=/etc/near-city-nodes/node.env
STEP=startup

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { STEP="$1"; printf '\n== %s\n' "$1"; }
trap 'printf "\nfailed during: %s\n" "$STEP" >&2' ERR

remote() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$@"; }

usage() { sed -n '2,9p' "$0" | sed 's/^# \?//' >&2; exit 2; }

[[ $# -eq 4 ]] || usage
TARGET="$1"
OPERATOR_NAME="$2"
NODE_PUBLIC_IP="$3"
TELEGRAM_CHAT_ID="$4"
TELEGRAM_BOT_TOKEN="${NODE_BOT_TOKEN:-}"

step "validate inputs"
[[ -n "$TELEGRAM_BOT_TOKEN" ]] || die "NODE_BOT_TOKEN is unset; pass the bot token by env, not argv"
[[ "$OPERATOR_NAME" =~ ^[a-z][a-z0-9-]+$ ]] || die "operator name must be kebab-case: got '$OPERATOR_NAME'"
[[ "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]] || die "chat id must be numeric: got '$TELEGRAM_CHAT_ID'"
[[ "$NODE_PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "public ip must be IPv4: got '$NODE_PUBLIC_IP'"
for octet in ${NODE_PUBLIC_IP//./ }; do
    (( octet <= 255 )) || die "public ip octet out of range: '$NODE_PUBLIC_IP'"
done
[[ -f "$OPERATOR_PUBKEY" ]] || die "operator public key not found: $OPERATOR_PUBKEY"
[[ "$TARGET" != "$REF_HOST" ]] || die "target host and REF_HOST must differ"
printf '  target=%s operator=%s ip=%s ref=%s tag=%s\n' \
    "$TARGET" "$OPERATOR_NAME" "$NODE_PUBLIC_IP" "$REF_HOST" "$IMAGE_TAG"

step "check hosts"
remote "$TARGET" true || die "cannot ssh to $TARGET"
remote "$REF_HOST" "docker image inspect nearcore:${IMAGE_TAG} >/dev/null 2>&1" \
    || die "$REF_HOST does not hold nearcore:${IMAGE_TAG}"

step "refuse to clobber a staked validator"
pool=$(remote "$TARGET" "sed -n 's/^POOL_ACCOUNT=//p' '$ENV_FILE' 2>/dev/null || true")
[[ -z "$pool" || "$FORCE" == "1" ]] \
    || die "$TARGET already carries POOL_ACCOUNT=$pool; set FORCE=1 to redeploy anyway"
printf '  no pool account on target\n'

step "read fleet telegram credentials from $REF_HOST"
fleet_creds=$(remote "$REF_HOST" "grep -E '^TELEGRAM_FLEET_(BOT_TOKEN|CHAT_ID)=' '$ENV_FILE'")
[[ $(grep -c '=' <<<"$fleet_creds") -eq 2 ]] || die "fleet telegram credentials incomplete on $REF_HOST"
printf '  fleet credentials loaded\n'

step "sync repository to $TARGET"
rsync -az --exclude='.git' --exclude='nearcore/' --exclude='*.log' \
    "$REPO_DIR/" "$TARGET:/opt/near-city-nodes/"

step "install $ENV_FILE and operator key"
remote "$TARGET" 'install -d -m 700 -o root -g root /etc/near-city-nodes'
{
    cat <<ENV
OPERATOR_NAME=$OPERATOR_NAME
OPERATOR_USER=validator
OPERATOR_SSH_PUBKEYS_FILE=/etc/near-city-nodes/operator_authorized_keys
NODE_PUBLIC_IP=$NODE_PUBLIC_IP
NETWORK=mainnet
NEARCORE_TAG=$IMAGE_TAG
EPOCH_LENGTH=43200
NEAR_RPC_URL=https://rpc.mainnet.near.org
POOL_ACCOUNT=
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
SERVICE_NAME=neard-mainnet
IMAGE_NAME=nearcore
DOCKER_BUILD_CONTEXT=/opt/nearcore-docker
LOCAL_STATUS_URL=http://localhost:3030/status
LOCAL_METRICS_URL=http://localhost:3030/metrics
VERSION_FILE=/var/lib/near-city-nodes/current_version
KEEP_IMAGES=3
MAX_EPOCH_PROGRESS=75
MIN_PEER_COUNT=20
STABILIZATION_WAIT=90
PAUSE_FILE=/etc/near-city-nodes/pause-upgrades
AUDIT_LOG=/var/log/near-city-nodes/update.log
STAGED_FILE=/var/lib/near-city-nodes/staged-upgrade
NEAR_DATA_DIR=/var/lib/neard/.near/data
SNAPSHOT_DIR=/var/lib/neard/.near/data.pre-upgrade-snapshot
GRAFANA_ADMIN_PASSWORD=
GRAFANA_BIND_ADDRESS=0.0.0.0
ENV
    printf '%s\n' "$fleet_creds"
} | remote "$TARGET" "install -m 600 -o root -g root /dev/stdin '$ENV_FILE'"

scp -q "$OPERATOR_PUBKEY" "$TARGET:/tmp/operator_authorized_keys"
remote "$TARGET" 'install -m 644 -o root -g root /tmp/operator_authorized_keys \
    /etc/near-city-nodes/operator_authorized_keys && rm -f /tmp/operator_authorized_keys'
printf '  node.env installed (0600), operator key in place\n'

step "bootstrap phases 00-04"
remote "$TARGET" 'cd /opt/near-city-nodes && ./bootstrap.sh --to 04-docker'

step "provision nearcore:${IMAGE_TAG}"
if remote "$TARGET" "docker image inspect nearcore:${IMAGE_TAG} >/dev/null 2>&1"; then
    printf '  image already present on target\n'
else
    printf '  streaming from %s, timeout %ss\n' "$REF_HOST" "$TRANSFER_TIMEOUT"
    timeout "$TRANSFER_TIMEOUT" bash -c "
        ssh -o BatchMode=yes -C '$REF_HOST' 'docker save nearcore:${IMAGE_TAG}' \
        | ssh -o BatchMode=yes -C '$TARGET' 'docker load'" \
        || die "image transfer from $REF_HOST stalled or failed"
    remote "$TARGET" "docker image inspect nearcore:${IMAGE_TAG} >/dev/null 2>&1" \
        || die "image transfer completed but nearcore:${IMAGE_TAG} is not present on $TARGET"
fi

step "bootstrap phases 05-11"
remote "$TARGET" 'cd /opt/near-city-nodes && ./bootstrap.sh --from 05-neard-build'

step "verify $TARGET"
remote "$TARGET" '
rc=0
for unit in neard-mainnet prometheus prometheus-node-exporter grafana-server fail2ban; do
    state=$(systemctl is-active "$unit" || true)
    printf "  %-26s %s\n" "$unit" "$state"
    [ "$state" = active ] || rc=1
done
printf "  %-26s %s\n" neard \
    "$(curl -sf --max-time 10 http://localhost:3030/status | jq -c "{version:.version.version,syncing:.sync_info.syncing}")"
printf "  %-26s %s\n" grafana \
    "$(curl -sf --max-time 10 --retry 5 --retry-delay 2 http://localhost:3000/api/health | jq -c "{database,version}")"
printf "  %-26s %s\n" disk "$(df -h / | awk "NR==2 {print \$4 \" free of \" \$2}")"
journalctl -u neard-mainnet --no-pager | grep -oE "node_status=\"[^\"]*\"" | tail -1 | sed "s/^/  sync  /"
exit "$rc"'

printf '\n== %s deployed\n' "$TARGET"
