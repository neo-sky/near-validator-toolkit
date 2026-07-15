#!/bin/bash
# Build (or reuse) a nearcore image and distribute it to no-compile fleet hosts.
# Hosts running update-near.sh with BUILD_MODE=stage do not build on-box; they
# expect the image to be present, and this delivers it. After it lands, the
# host's next update-near.sh run applies it through the normal epoch-safe path.
#
# Usage: push-image-to-fleet.sh <nearcore-tag> [host ...]
# Hosts come from the arguments, or from FLEET_HOSTS (space-separated) if none
# are given.
# Env: IMAGE_NAME (default nearcore), DOCKERFILE_DIR (default repo root), FLEET_HOSTS

set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-nearcore}"
DOCKERFILE_DIR="${DOCKERFILE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

[[ $# -ge 1 ]] || { echo "usage: $0 <nearcore-tag> [host ...]" >&2; exit 2; }
TAG="$1"; shift
HOSTS=("$@")
[[ ${#HOSTS[@]} -gt 0 ]] || read -ra HOSTS <<<"${FLEET_HOSTS:-}"
[[ ${#HOSTS[@]} -gt 0 ]] || { echo "no target hosts: pass them as arguments or set FLEET_HOSTS" >&2; exit 2; }
REF="${IMAGE_NAME}:${TAG}"

step() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

step "ensure $REF exists locally"
if docker image inspect "$REF" >/dev/null 2>&1; then
    echo "  present, reusing"
else
    [[ -f "$DOCKERFILE_DIR/Dockerfile" ]] || die "no Dockerfile in $DOCKERFILE_DIR"
    echo "  building from $DOCKERFILE_DIR/Dockerfile (~15-20min)"
    ctx=$(mktemp -d)
    trap 'rm -rf "$ctx"' EXIT
    cp "$DOCKERFILE_DIR/Dockerfile" "$ctx/"
    docker build --build-arg "NEARCORE_TAG=$TAG" -t "$REF" "$ctx"
fi

step "distribute to ${#HOSTS[@]} host(s): ${HOSTS[*]}"
for h in "${HOSTS[@]}"; do
    printf '  %-9s ' "$h"
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$h" true 2>/dev/null || { echo "UNREACHABLE"; continue; }
    if docker save "$REF" | ssh -o BatchMode=yes -C "$h" 'docker load' >/dev/null 2>&1; then
        echo "loaded"
    else
        echo "LOAD FAILED"
    fi
done

step "done"
echo "  $REF delivered. Each stage-mode host applies it on its next update-near.sh run,"
echo "  or apply now: ssh <host> 'sudo /opt/near-city-nodes/update-near.sh'"
