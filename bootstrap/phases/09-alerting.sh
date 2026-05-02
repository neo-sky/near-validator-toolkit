#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/render.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0
load_env
require_var OPERATOR_NAME
require_var TELEGRAM_BOT_TOKEN
require_var TELEGRAM_CHAT_ID

export OPERATOR_NAME TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID

ALERT_DIR=/etc/grafana/provisioning/alerting
install -d -m 755 -o root -g grafana "$ALERT_DIR"

log "INFO render primary contact-point"
render_template \
    "$REPO_DIR/templates/grafana/provisioning/alerting/contact-points-primary.yaml.tmpl" \
    "$ALERT_DIR/contact-points-primary.yaml" \
    OPERATOR_NAME TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
chown root:grafana "$ALERT_DIR/contact-points-primary.yaml"
chmod 640 "$ALERT_DIR/contact-points-primary.yaml"

# Drop the legacy single-file name if it exists from a prior install
rm -f "$ALERT_DIR/contact-points.yaml"

if [[ -n "${TELEGRAM_FLEET_BOT_TOKEN:-}" && -n "${TELEGRAM_FLEET_CHAT_ID:-}" ]]; then
    export TELEGRAM_FLEET_BOT_TOKEN TELEGRAM_FLEET_CHAT_ID
    log "INFO render fleet contact-point"
    render_template \
        "$REPO_DIR/templates/grafana/provisioning/alerting/contact-points-fleet.yaml.tmpl" \
        "$ALERT_DIR/contact-points-fleet.yaml" \
        TELEGRAM_FLEET_BOT_TOKEN TELEGRAM_FLEET_CHAT_ID
    chown root:grafana "$ALERT_DIR/contact-points-fleet.yaml"
    chmod 640 "$ALERT_DIR/contact-points-fleet.yaml"
else
    log "INFO fleet vars unset; skipping fleet contact-point \
(orphan policy route will warn but primary stays functional)"
    rm -f "$ALERT_DIR/contact-points-fleet.yaml"
fi

log "INFO render policies"
render_template \
    "$REPO_DIR/templates/grafana/provisioning/alerting/policies.yaml.tmpl" \
    "$ALERT_DIR/policies.yaml" \
    OPERATOR_NAME
chown root:grafana "$ALERT_DIR/policies.yaml"
chmod 644 "$ALERT_DIR/policies.yaml"

log "INFO render rules"
render_template \
    "$REPO_DIR/templates/grafana/provisioning/alerting/rules.yaml.tmpl" \
    "$ALERT_DIR/rules.yaml" \
    OPERATOR_NAME
chown root:grafana "$ALERT_DIR/rules.yaml"
chmod 644 "$ALERT_DIR/rules.yaml"

log "INFO restart grafana to pick up alerting"
systemctl restart grafana-server

log "OK Grafana alerting provisioned"
mark_phase_done
