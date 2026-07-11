#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0

export DEBIAN_FRONTEND=noninteractive

log "INFO apt lock timeout (unattended-upgrades may hold dpkg on first boot)"
install -d -m 755 -o root -g root /etc/apt/apt.conf.d
printf 'DPkg::Lock::Timeout "600";\n' > /etc/apt/apt.conf.d/99-lock-timeout
chmod 644 /etc/apt/apt.conf.d/99-lock-timeout

log "INFO apt update"
retry 3 10 apt-get update -y -q

log "INFO installing base packages"
apt-get install -y -q --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    gnupg \
    gettext-base \
    cron \
    logrotate \
    rsync \
    net-tools \
    ufw \
    fail2ban \
    unattended-upgrades \
    chrony

log "INFO enable chrony for time sync"
systemctl enable --now chrony

log "INFO timezone -> UTC"
timedatectl set-timezone UTC

log "OK base packages installed"
mark_phase_done
