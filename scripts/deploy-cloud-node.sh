#!/bin/bash
# Deploy one NEAR validator node onto a provisioned Ubuntu host.
# Usage:
#   NODE_BOT_TOKEN=<token> IMAGE_REGISTRY=ghcr.io/<org> OPERATOR_PUBKEY=<path> \
#     deploy-cloud-node.sh <ssh-host> <operator-name> <public-ipv4> <chat-id>
#
# The host pulls its prebuilt neard image from IMAGE_REGISTRY and never compiles.
# The bot token is read from NODE_BOT_TOKEN so it never lands in argv. FORCE=1
# permits redeploying a host that already carries a pool account.
#
# Required env: NODE_BOT_TOKEN, IMAGE_REGISTRY, OPERATOR_PUBKEY
# Optional env: FLEET_BOT_TOKEN, FLEET_CHAT_ID, IMAGE_TAG, NETWORK, OPERATOR_USER, FORCE

set -euo pipefail

IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"
OPERATOR_PUBKEY="${OPERATOR_PUBKEY:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
NETWORK="${NETWORK:-mainnet}"
OPERATOR_USER="${OPERATOR_USER:-validator}"
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
[[ -n "$IMAGE_REGISTRY" ]] || die "IMAGE_REGISTRY is unset; e.g. ghcr.io/<org>"
[[ -n "$OPERATOR_PUBKEY" ]] || die "OPERATOR_PUBKEY is unset; name the public key to install for $OPERATOR_USER"
[[ -f "$OPERATOR_PUBKEY" ]] || die "operator public key not found: $OPERATOR_PUBKEY"
[[ "$NETWORK" =~ ^(mainnet|testnet)$ ]] || die "NETWORK must be mainnet or testnet: got '$NETWORK'"
[[ "$OPERATOR_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "operator user must be a valid unix name: got '$OPERATOR_USER'"
[[ "$OPERATOR_NAME" =~ ^[a-z][a-z0-9-]+$ ]] || die "operator name must be kebab-case: got '$OPERATOR_NAME'"
[[ "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]] || die "chat id must be numeric: got '$TELEGRAM_CHAT_ID'"
[[ "$NODE_PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "public ip must be IPv4: got '$NODE_PUBLIC_IP'"
for octet in ${NODE_PUBLIC_IP//./ }; do
    (( 10#$octet <= 255 )) || die "public ip octet out of range: '$NODE_PUBLIC_IP'"
done

if [[ -z "$IMAGE_TAG" ]]; then
    IMAGE_TAG=$(curl -fsSL https://api.github.com/repos/near/nearcore/releases/latest | jq -r .tag_name | sed 's/^v//')
    [[ -n "$IMAGE_TAG" && "$IMAGE_TAG" != null ]] || die "could not resolve latest nearcore release; set IMAGE_TAG"
fi
printf '  target=%s operator=%s ip=%s registry=%s tag=%s\n' \
    "$TARGET" "$OPERATOR_NAME" "$NODE_PUBLIC_IP" "$IMAGE_REGISTRY" "$IMAGE_TAG"

step "check host"
remote "$TARGET" true || die "cannot ssh to $TARGET"

step "refuse to clobber a staked validator"
pool=$(remote "$TARGET" "sed -n 's/^POOL_ACCOUNT=//p' '$ENV_FILE' 2>/dev/null || true")
[[ -z "$pool" || "$FORCE" == "1" ]] \
    || die "$TARGET already carries POOL_ACCOUNT=$pool; set FORCE=1 to redeploy anyway"
printf '  no pool account on target\n'

step "sync repository to $TARGET"
rsync -az --exclude='.git' --exclude='nearcore/' --exclude='*.log' \
    "$REPO_DIR/" "$TARGET:/opt/near-city-nodes/"

step "install $ENV_FILE and operator key"
remote "$TARGET" 'install -d -m 700 -o root -g root /etc/near-city-nodes'
{
    cat <<ENV
OPERATOR_NAME=$OPERATOR_NAME
OPERATOR_USER=$OPERATOR_USER
OPERATOR_SSH_PUBKEYS_FILE=/etc/near-city-nodes/operator_authorized_keys
NODE_PUBLIC_IP=$NODE_PUBLIC_IP
NETWORK=$NETWORK
NEARCORE_TAG=$IMAGE_TAG
EPOCH_LENGTH=43200
NEAR_RPC_URL=https://rpc.$NETWORK.near.org
POOL_ACCOUNT=
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
TELEGRAM_FLEET_BOT_TOKEN=${FLEET_BOT_TOKEN:-}
TELEGRAM_FLEET_CHAT_ID=${FLEET_CHAT_ID:-}
SERVICE_NAME=neard-$NETWORK
IMAGE_NAME=nearcore
IMAGE_REGISTRY=$IMAGE_REGISTRY
BUILD_MODE=pull
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
} | remote "$TARGET" "cat > '$ENV_FILE' && chown root:root '$ENV_FILE' && chmod 600 '$ENV_FILE'"

scp -q "$OPERATOR_PUBKEY" "$TARGET:/tmp/operator_authorized_keys"
remote "$TARGET" 'install -m 644 -o root -g root /tmp/operator_authorized_keys \
    /etc/near-city-nodes/operator_authorized_keys && rm -f /tmp/operator_authorized_keys'
printf '  node.env installed (0600), operator key in place\n'

step "bootstrap"
remote "$TARGET" 'cd /opt/near-city-nodes && ./bootstrap.sh'

step "verify $TARGET"
remote "$TARGET" "
rc=0
for unit in neard-$NETWORK prometheus prometheus-node-exporter grafana-server fail2ban; do
    state=\$(systemctl is-active \"\$unit\" || true)
    printf '  %-26s %s\n' \"\$unit\" \"\$state\"
    [ \"\$state\" = active ] || rc=1
done
printf '  %-26s %s\n' neard \
    \"\$(curl -sf --max-time 10 http://localhost:3030/status | jq -c '{version:.version.version,syncing:.sync_info.syncing}')\"
printf '  %-26s %s\n' grafana \
    \"\$(curl -sf --max-time 10 --retry 5 --retry-delay 2 http://localhost:3000/api/health | jq -c '{database,version}')\"
printf '  %-26s %s\n' disk \"\$(df -h / | awk 'NR==2 {print \$4 \" free of \" \$2}')\"
journalctl -u neard-$NETWORK --no-pager | grep -oE 'node_status=\"[^\"]*\"' | tail -1 | sed 's/^/  sync  /'
exit \$rc"

printf '\n== %s deployed\n' "$TARGET"
