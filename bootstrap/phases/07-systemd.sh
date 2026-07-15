#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0
load_env
require_var SERVICE_NAME

log "INFO install $SERVICE_NAME unit"
install -m 644 -o root -g root \
    "$REPO_DIR/systemd/${SERVICE_NAME}.service" \
    "/etc/systemd/system/${SERVICE_NAME}.service"
sed -i "s#__NEARD_UID__:__NEARD_GID__#$(id -u neard):$(id -g neard)#" \
    "/etc/systemd/system/${SERVICE_NAME}.service"

mem_mb=$(awk '/^MemTotal:/ {printf "%d", $2 / 1024 * 85 / 100}' /proc/meminfo)
sed -i "s#__NEARD_MEM__#${mem_mb}m#" \
    "/etc/systemd/system/${SERVICE_NAME}.service"

log "INFO copy update-near.sh to /opt/near-city-nodes/"
if [ "$(realpath -m "$REPO_DIR/update-near.sh")" != "$(realpath -m /opt/near-city-nodes/update-near.sh)" ]; then
    install -m 755 -o root -g root \
        "$REPO_DIR/update-near.sh" \
        /opt/near-city-nodes/update-near.sh
else
    log "INFO update-near.sh already in place (REPO_DIR == /opt/near-city-nodes)"
    chmod 755 /opt/near-city-nodes/update-near.sh
    chown root:root /opt/near-city-nodes/update-near.sh
fi

log "INFO symlink env so update-near.sh finds it"
ln -sf /etc/near-city-nodes/node.env /opt/near-city-nodes/.env

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

sleep 5
systemctl is-active --quiet "$SERVICE_NAME" \
    || die "$SERVICE_NAME failed to start (journalctl -u $SERVICE_NAME)"

log "OK $SERVICE_NAME active"
mark_phase_done
