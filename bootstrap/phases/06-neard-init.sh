#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0
load_env
require_var NETWORK
require_var NODE_PUBLIC_IP
require_var IMAGE_NAME

NEAR_HOME=/var/lib/neard/.near
ACCOUNT_ID="${POOL_ACCOUNT:-placeholder.near}"

if [[ -f "$NEAR_HOME/validator_key.json" && -f "$NEAR_HOME/node_key.json" && -f "$NEAR_HOME/config.json" ]]; then
    log "INFO neard already initialized; refreshing public_addrs and account_id only"
else
    log "INFO running neard init (downloads genesis manifest, generates keys)"
    docker run --rm \
        -v "$NEAR_HOME:/home/neard/.near" \
        -u "$(id -u neard):$(id -g neard)" \
        --entrypoint /usr/local/bin/neard \
        "${IMAGE_NAME}:current" \
        --home /home/neard/.near init \
            --chain-id "$NETWORK" \
            --account-id "$ACCOUNT_ID" \
            --download-genesis \
            --download-config \
        || die "neard init failed"
fi

if [[ "$NETWORK" == "mainnet" ]]; then
    log "INFO replace config.json with canonical mainnet fleet template"
    [[ -f "$REPO_DIR/templates/neard/config.json" ]] \
        || die "fleet config template missing at $REPO_DIR/templates/neard/config.json"
    install -m 644 -o neard -g neard \
        "$REPO_DIR/templates/neard/config.json" \
        "$NEAR_HOME/config.json"
else
    log "INFO testnet: keeping neard's downloaded config.json (no fleet template for testnet)"
fi

log "INFO inject network.public_addrs"
NODE_KEY_PUB=$(jq -r .public_key "$NEAR_HOME/node_key.json")
[[ -n "$NODE_KEY_PUB" && "$NODE_KEY_PUB" != "null" ]] || die "could not read node_key.json public_key"
PUBLIC_ADDR="${NODE_KEY_PUB}@${NODE_PUBLIC_IP}:24567"
jq --arg a "$PUBLIC_ADDR" '.network.public_addrs = [$a]' \
    "$NEAR_HOME/config.json" > "$NEAR_HOME/config.json.new"
mv "$NEAR_HOME/config.json.new" "$NEAR_HOME/config.json"
chown neard:neard "$NEAR_HOME/config.json"

log "INFO set validator_key.json account_id -> $ACCOUNT_ID"
jq --arg a "$ACCOUNT_ID" '.account_id = $a' \
    "$NEAR_HOME/validator_key.json" > "$NEAR_HOME/validator_key.json.new"
mv "$NEAR_HOME/validator_key.json.new" "$NEAR_HOME/validator_key.json"
chown neard:neard "$NEAR_HOME/validator_key.json"
chmod 600 "$NEAR_HOME/validator_key.json"

VALIDATOR_PUB=$(jq -r .public_key "$NEAR_HOME/validator_key.json")
install -d -m 755 -o root -g root /var/lib/near-city-nodes
printf '%s\n' "$VALIDATOR_PUB" > /var/lib/near-city-nodes/validator_pubkey.txt
chmod 644 /var/lib/near-city-nodes/validator_pubkey.txt

log "OK validator pubkey: $VALIDATOR_PUB"
log "OK config public_addrs: $PUBLIC_ADDR"
mark_phase_done
