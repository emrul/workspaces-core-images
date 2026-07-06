#!/bin/bash

## Parse input ##
NAME1=$1
NAME2=$2
BASE=$3
BG=$4
DISTRO=$5
DOCKERFILE=$6
# Optional: space-separated extra --build-arg flags for parameterised Dockerfiles
# (e.g. dockerfile-nix-app needs NIX_ATTR, PROFILE_NAME, NIXPKGS_REV, GPU_SUPPORT).
EXTRA_BUILD_ARGS=${7:-}

## Build/Push image to cache endpoint by pipeline ID ##
# shellcheck disable=SC2086 — EXTRA_BUILD_ARGS is intentionally word-split
docker build --provenance=false \
  -t ${ORG_NAME}/image-cache-private:$(arch)-core-${NAME1}-${NAME2}-${SANITIZED_BRANCH}-${CI_PIPELINE_ID} \
  --build-arg BASE_IMAGE="${BASE}" \
  --build-arg DISTRO="${DISTRO}" \
  --build-arg BG_IMG="${BG}" \
  ${EXTRA_BUILD_ARGS} \
  -f ${DOCKERFILE} .
docker push ${ORG_NAME}/image-cache-private:$(arch)-core-${NAME1}-${NAME2}-${SANITIZED_BRANCH}-${CI_PIPELINE_ID}
