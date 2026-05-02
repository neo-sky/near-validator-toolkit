#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

load_env

NEAR_HOME=/var/lib/neard/.near
PUBKEY_FILE=/var/lib/near-city-nodes/validator_pubkey.txt
VALIDATOR_PUB="(unavailable)"
[[ -f "$PUBKEY_FILE" ]] && VALIDATOR_PUB=$(< "$PUBKEY_FILE")

NODE_PUB="(unavailable)"
[[ -f "$NEAR_HOME/node_key.json" ]] && NODE_PUB=$(jq -r .public_key "$NEAR_HOME/node_key.json")

GRAFANA_PW="(see /root/.grafana_admin_password)"
[[ -f /root/.grafana_admin_password && "$EUID" -eq 0 ]] \
    && GRAFANA_PW=$(< /root/.grafana_admin_password)

PLACEHOLDERS=""
[[ -z "${POOL_ACCOUNT:-}" ]] \
    && PLACEHOLDERS+=$'  - POOL_ACCOUNT empty; pool not on-chain yet (account_id=placeholder.near)\n'
[[ ! -f /etc/near-city-nodes/operator_authorized_keys ]] \
    && PLACEHOLDERS+="  - operator_authorized_keys missing; ${OPERATOR_USER} cannot ssh until populated"$'\n'
if [[ -f /var/lib/neard/.near/validator_key.json ]] \
   && [[ "$(jq -r .account_id /var/lib/neard/.near/validator_key.json)" == "placeholder.near" ]]; then
    PLACEHOLDERS+=$'  - validator_key.json account_id=placeholder.near; re-run phase 06 --force when POOL_ACCOUNT set\n'
fi

cat <<EOF

============================================================
Validator node deployed: ${OPERATOR_NAME}
============================================================
  network          : ${NETWORK}
  nearcore tag     : ${NEARCORE_TAG}
  pool account     : ${POOL_ACCOUNT:-(not yet deployed)}
  public IP        : ${NODE_PUBLIC_IP}

  validator pubkey : ${VALIDATOR_PUB}
  node pubkey      : ${NODE_PUB}
  public_addrs     : ${NODE_PUB}@${NODE_PUBLIC_IP}:24567

  Grafana          : http://${NODE_PUBLIC_IP}:3000
  admin user       : admin
  admin password   : ${GRAFANA_PW}

$( [[ -n "$PLACEHOLDERS" ]] && { echo 'Outstanding placeholders (node not fully deployed):'; printf '%b' "$PLACEHOLDERS"; } )

Next steps:
  1. Send the validator pubkey above to whoever runs scripts/deploy-pool.sh.
  2. Once the pool exists and POOL_ACCOUNT is filled in node.env, re-run:
       ./bootstrap.sh --phase 06-neard-init --force
       ./bootstrap.sh --phase 08-monitoring --force
       systemctl restart neard-mainnet
  3. Operator: ssh in as ${OPERATOR_USER}, watch sync:
       curl -s http://localhost:3030/status | jq .sync_info
  4. Telegram delivery is exercised on real upgrade activity. To smoke-test
     wiring at deploy time, run as root:
       source /etc/near-city-nodes/node.env
       curl -s "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \\
         --data-urlencode "chat_id=\${TELEGRAM_CHAT_ID}" \\
         --data-urlencode "text=*\${OPERATOR_NAME}* | [TEST] wiring"
============================================================
EOF
