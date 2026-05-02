#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0
load_env
require_var OPERATOR_USER

OPERATOR_PUBKEYS_FILE="${OPERATOR_SSH_PUBKEYS_FILE:-/etc/near-city-nodes/operator_authorized_keys}"

log "INFO neard system user (uid 998)"
if ! getent group neard >/dev/null; then
    groupadd --system --gid 998 neard
fi
if ! getent passwd neard >/dev/null; then
    useradd --system --uid 998 --gid 998 \
        --home-dir /var/lib/neard --no-create-home \
        --shell /usr/sbin/nologin neard
fi

log "INFO directories + ownership"
install -d -m 750 -o neard -g neard /var/lib/neard
install -d -m 775 -o neard -g neard /var/lib/neard/.near
install -d -m 2750 -o neard -g adm /var/log/near-city-nodes
install -d -m 700 -o root -g root /etc/near-city-nodes
install -d -m 755 -o root -g root /var/lib/near-city-nodes
install -d -m 755 -o root -g root /opt/near-city-nodes
install -d -m 755 -o root -g root /opt/nearcore-docker

log "INFO operator user: $OPERATOR_USER"
if ! getent passwd "$OPERATOR_USER" >/dev/null; then
    adduser --disabled-password --gecos "" "$OPERATOR_USER"
fi

install -d -m 700 -o "$OPERATOR_USER" -g "$OPERATOR_USER" \
    "/home/$OPERATOR_USER/.ssh"

if [[ -f "$OPERATOR_PUBKEYS_FILE" ]]; then
    install -m 600 -o "$OPERATOR_USER" -g "$OPERATOR_USER" \
        "$OPERATOR_PUBKEYS_FILE" \
        "/home/$OPERATOR_USER/.ssh/authorized_keys"
    log "OK installed operator pubkeys from $OPERATOR_PUBKEYS_FILE"
else
    log "WARN $OPERATOR_PUBKEYS_FILE not present; operator cannot ssh in until populated"
    touch "/home/$OPERATOR_USER/.ssh/authorized_keys"
    chown "$OPERATOR_USER:$OPERATOR_USER" "/home/$OPERATOR_USER/.ssh/authorized_keys"
    chmod 600 "/home/$OPERATOR_USER/.ssh/authorized_keys"
fi

log "INFO operator sudoers drop-in"
SUDOERS_TMP=$(mktemp)
trap 'rm -f "$SUDOERS_TMP"' EXIT
OPERATOR_USER="$OPERATOR_USER" envsubst '${OPERATOR_USER}' \
    < "$REPO_DIR/templates/sudoers/90-cityops" > "$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP" >/dev/null \
    || die "sudoers template did not pass visudo check"
install -m 440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/90-cityops

log "OK users + dirs ready"
mark_phase_done
