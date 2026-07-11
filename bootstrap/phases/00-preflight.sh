#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0

[[ "$EUID" -eq 0 ]] || die "must run as root"

. /etc/os-release
[[ "$ID" == "ubuntu" ]] || die "OS check: expected Ubuntu, got $PRETTY_NAME"
case "$VERSION_ID" in
    22.04|24.04|26.04) ;;
    *) die "OS check: expected Ubuntu 22.04, 24.04, or 26.04, got $PRETTY_NAME" ;;
esac

[[ -f "$ENV_FILE" ]] || die "env file missing: $ENV_FILE"
load_env

for v in OPERATOR_NAME OPERATOR_USER NODE_PUBLIC_IP NETWORK NEARCORE_TAG \
         TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
    require_var "$v"
done

[[ "$OPERATOR_NAME" =~ ^[a-z][a-z0-9-]+$ ]] \
    || die "OPERATOR_NAME must be kebab-case lowercase: got '$OPERATOR_NAME'"
[[ "$OPERATOR_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] \
    || die "OPERATOR_USER must be a valid unix username: got '$OPERATOR_USER'"
[[ "$NODE_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "NODE_PUBLIC_IP must be a dotted IPv4: got '$NODE_PUBLIC_IP'"
[[ "$NETWORK" =~ ^(mainnet|testnet)$ ]] \
    || die "NETWORK must be mainnet or testnet: got '$NETWORK'"

required_ram_gb=6
required_disk_gb=60
if [[ "$NETWORK" == "testnet" ]]; then
    required_disk_gb=40
fi

ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
ram_gb=$(( ram_kb / 1024 / 1024 ))
(( ram_gb >= required_ram_gb )) \
    || die "RAM check: ${ram_gb}G < required ${required_ram_gb}G (NETWORK=$NETWORK)"

root_avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
(( root_avail_gb >= required_disk_gb )) \
    || die "disk check: / has ${root_avail_gb}G free, need >=${required_disk_gb}G (NETWORK=$NETWORK)"

if grep -q '^md' /proc/mdstat 2>/dev/null; then
    log "INFO mdraid present"
else
    log "WARN no mdraid found on /proc/mdstat, single-disk install"
fi

retry 3 5 curl -fsS --max-time 10 https://api.github.com >/dev/null \
    || die "internet check: cannot reach api.github.com"

log "OK preflight passed (Ubuntu $VERSION_ID, ${ram_gb}G RAM, ${root_avail_gb}G free, \
NETWORK=$NETWORK, operator=$OPERATOR_NAME)"
mark_phase_done
