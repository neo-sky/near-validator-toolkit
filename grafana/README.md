# Grafana dashboards

`city-node.json` is the per-validator dashboard. It uses a `$node` template variable populated from `label_values(up{job="neard"}, host)`, so the same file works on every node and is forward-compatible with a centralized Grafana that scrapes multiple validators.

## Provisioning paths on the host

- Dashboard provider: `/etc/grafana/provisioning/dashboards/city-node-fleet.yaml`
- Dashboard JSON: `/var/lib/grafana/dashboards/city-node.json`
- Datasource: `/etc/grafana/provisioning/datasources/prometheus.yaml` (UID `city-node-prometheus`, fixed across the fleet)

## Updating the dashboard

1. Edit live in Grafana on any node.
2. `Share -> Export -> Save to file`, replace `grafana/city-node.json` in this repo.
3. Commit, push, then on each node:
   ```
   cd /opt/near-city-nodes && git pull
   ./bootstrap.sh --phase 08-monitoring --force
   ```

The `$node` variable and datasource UID must remain intact across edits or panels will break.
