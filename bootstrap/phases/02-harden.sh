#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0

log "INFO install sshd hardening drop-in"
install -m 644 -o root -g root \
    "$REPO_DIR/templates/ssh/50-cityops.conf" \
    /etc/ssh/sshd_config.d/50-cityops.conf
sshd -t || die "sshd config invalid after drop-in"
systemctl reload ssh

log "INFO install sysctl hardening"
install -m 644 -o root -g root \
    "$REPO_DIR/templates/sysctl/90-security-hardening.conf" \
    /etc/sysctl.d/90-security-hardening.conf
sysctl --system >/dev/null

log "INFO apply UFW rules"
bash "$REPO_DIR/templates/ufw/rules.sh"

log "INFO install fail2ban jail"
install -m 644 -o root -g root \
    "$REPO_DIR/templates/fail2ban/jail.local" \
    /etc/fail2ban/jail.d/defaults-cityops.conf
systemctl enable --now fail2ban
systemctl restart fail2ban

log "INFO install unattended-upgrades drop-in"
install -m 644 -o root -g root \
    "$REPO_DIR/templates/unattended-upgrades/51-cityops.conf" \
    /etc/apt/apt.conf.d/51-cityops
systemctl enable --now unattended-upgrades

log "INFO mask + purge snapd if present"
if dpkg -l snapd 2>/dev/null | grep -q "^ii"; then
    systemctl stop snapd snapd.socket snapd.seeded 2>/dev/null || true
    systemctl mask snapd snapd.socket snapd.seeded 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y snapd
    apt-mark hold snapd
    log "OK snapd purged + held"
else
    log "OK snapd not installed"
fi

log "OK host hardened"
mark_phase_done
