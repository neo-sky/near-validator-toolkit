#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/common.sh"

phase_done && exit 0
load_env
require_var NEARCORE_TAG
require_var IMAGE_NAME

BUILD_MODE="${BUILD_MODE:-build}"
ref="${IMAGE_NAME}:${NEARCORE_TAG}"

if docker image inspect "$ref" >/dev/null 2>&1; then
    log "INFO image $ref already present"
elif [[ "$BUILD_MODE" == "pull" ]]; then
    require_var IMAGE_REGISTRY
    src="${IMAGE_REGISTRY}/${ref}"
    log "INFO pulling $src"
    docker pull "$src" || die "docker pull failed for $src"
    docker tag "$src" "$ref"
elif [[ "$BUILD_MODE" == "build" ]]; then
    require_var DOCKER_BUILD_CONTEXT
    log "INFO seed docker build context at $DOCKER_BUILD_CONTEXT"
    install -d -m 755 "$DOCKER_BUILD_CONTEXT"
    install -m 644 -o root -g root "$REPO_DIR/Dockerfile" "$DOCKER_BUILD_CONTEXT/Dockerfile"
    install -m 644 -o root -g root "$REPO_DIR/.dockerignore" "$DOCKER_BUILD_CONTEXT/.dockerignore"
    log "INFO building $ref (~15-20 min)"
    docker build --build-arg "NEARCORE_TAG=$NEARCORE_TAG" -t "$ref" "$DOCKER_BUILD_CONTEXT" \
        || die "docker build failed for $NEARCORE_TAG"
else
    die "image $ref absent and BUILD_MODE=$BUILD_MODE cannot fetch it; deliver it with scripts/push-image-to-fleet.sh before bootstrap"
fi

log "INFO retag :current -> $NEARCORE_TAG"
docker tag "$ref" "${IMAGE_NAME}:current"

install -d -m 755 -o root -g root /var/lib/near-city-nodes
printf '%s' "$NEARCORE_TAG" > /var/lib/near-city-nodes/current_version

log "OK image ready; ${IMAGE_NAME}:current -> $NEARCORE_TAG"
mark_phase_done
