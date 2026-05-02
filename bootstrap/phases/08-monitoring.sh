#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/render.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0
load_env
require_var OPERATOR_NAME
require_var NETWORK

POOL_ACCOUNT="${POOL_ACCOUNT:-unset}"
export POOL_ACCOUNT OPERATOR_NAME NETWORK

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    if [[ -f /root/.grafana_admin_password ]]; then
        GRAFANA_ADMIN_PASSWORD=$(< /root/.grafana_admin_password)
        log "INFO reusing existing /root/.grafana_admin_password"
    else
        GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 20)
        printf '%s\n' "$GRAFANA_ADMIN_PASSWORD" > /root/.grafana_admin_password
        chmod 600 /root/.grafana_admin_password
        log "INFO generated new grafana admin password -> /root/.grafana_admin_password"
    fi
fi
GRAFANA_BIND_ADDRESS="${GRAFANA_BIND_ADDRESS:-0.0.0.0}"
export GRAFANA_ADMIN_PASSWORD GRAFANA_BIND_ADDRESS

export DEBIAN_FRONTEND=noninteractive

if [ ! -f /etc/apt/keyrings/grafana.gpg ] || [ ! -f /etc/apt/sources.list.d/grafana.list ]; then
    log "INFO add grafana apt repo"
    install -d -m 755 -o root -g root /etc/apt/keyrings
    curl -fsS https://apt.grafana.com/gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list
    apt-get update -y -q
fi

log "INFO install prometheus + node-exporter + grafana"
apt-get install -y -q --no-install-recommends \
    prometheus prometheus-node-exporter grafana

log "INFO render prometheus.yml"
render_template \
    "$REPO_DIR/templates/prometheus/prometheus.yml.tmpl" \
    /etc/prometheus/prometheus.yml \
    OPERATOR_NAME NETWORK POOL_ACCOUNT
chown root:root /etc/prometheus/prometheus.yml
chmod 644 /etc/prometheus/prometheus.yml

log "INFO render grafana.ini"
render_template \
    "$REPO_DIR/templates/grafana/grafana.ini.tmpl" \
    /etc/grafana/grafana.ini \
    GRAFANA_BIND_ADDRESS GRAFANA_ADMIN_PASSWORD
chown root:grafana /etc/grafana/grafana.ini
chmod 640 /etc/grafana/grafana.ini

log "INFO install grafana datasource + dashboard provisioning"
install -d -m 755 -o root -g root \
    /etc/grafana/provisioning/datasources \
    /etc/grafana/provisioning/dashboards \
    /var/lib/grafana/dashboards
install -m 644 -o root -g grafana \
    "$REPO_DIR/templates/grafana/provisioning/datasources/prometheus.yaml" \
    /etc/grafana/provisioning/datasources/prometheus.yaml
install -m 644 -o root -g grafana \
    "$REPO_DIR/templates/grafana/provisioning/dashboards/legion-fleet.yaml" \
    /etc/grafana/provisioning/dashboards/legion-fleet.yaml
install -m 644 -o grafana -g grafana \
    "$REPO_DIR/grafana/legion-node.json" \
    /var/lib/grafana/dashboards/legion-node.json

log "INFO restart prometheus + node-exporter + grafana"
systemctl enable --now prometheus prometheus-node-exporter grafana-server
systemctl restart prometheus
systemctl restart grafana-server

log "OK monitoring stack up"
mark_phase_done
