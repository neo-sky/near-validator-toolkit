#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0

export DEBIAN_FRONTEND=noninteractive

log "INFO installing docker.io"
apt-get install -y -q --no-install-recommends docker.io docker-buildx

log "INFO enable docker"
systemctl enable --now docker

if ! docker info >/dev/null 2>&1; then
    die "docker is installed but daemon not responding"
fi

log "OK docker $(docker --version)"
mark_phase_done
