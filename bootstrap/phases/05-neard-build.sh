#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0
load_env
require_var NEARCORE_TAG
require_var IMAGE_NAME
require_var DOCKER_BUILD_CONTEXT

log "INFO seed docker build context at $DOCKER_BUILD_CONTEXT"
install -d -m 755 "$DOCKER_BUILD_CONTEXT"
install -m 644 -o root -g root "$REPO_DIR/Dockerfile" "$DOCKER_BUILD_CONTEXT/Dockerfile"
install -m 644 -o root -g root "$REPO_DIR/.dockerignore" "$DOCKER_BUILD_CONTEXT/.dockerignore"

if docker image inspect "${IMAGE_NAME}:${NEARCORE_TAG}" >/dev/null 2>&1; then
    log "INFO image ${IMAGE_NAME}:${NEARCORE_TAG} already built; skipping build"
else
    log "INFO building ${IMAGE_NAME}:${NEARCORE_TAG} (~15-20 min)"
    docker build \
        --build-arg "NEARCORE_TAG=$NEARCORE_TAG" \
        -t "${IMAGE_NAME}:${NEARCORE_TAG}" \
        "$DOCKER_BUILD_CONTEXT" \
        || die "docker build failed for ${NEARCORE_TAG}"
fi

log "INFO retag :current -> ${NEARCORE_TAG}"
docker tag "${IMAGE_NAME}:${NEARCORE_TAG}" "${IMAGE_NAME}:current"

install -d -m 755 -o root -g root /var/lib/near-city-nodes
printf '%s' "$NEARCORE_TAG" > /var/lib/near-city-nodes/current_version

log "OK build complete; ${IMAGE_NAME}:current -> ${NEARCORE_TAG}"
mark_phase_done
